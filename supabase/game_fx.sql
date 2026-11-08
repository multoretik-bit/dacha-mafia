-- 08.11.2026: «кто что сделал» для звуков и анимаций (state.la) и честные фишки при уходе из-за стола.

create or replace function durak_play(g uuid, act text, card text default null, i int default null)
returns void language plpgsql security definer set search_path = public as $$
declare r world_games; st jsonb; tbl jsonb; h text[]; tr text; att uuid; def uuid; me_ uuid := auth.uid();
        ranks text[]; open_ int; a_c text; lim int; passed uuid[]; done_ uuid[]; nick text; la_ jsonb;
begin
  select * into r from world_games where id = g for update;
  if not found or r.kind <> 'durak' or not (me_ = any(r.players)) then raise exception 'not your game'; end if;
  if r.status <> 'active' then raise exception 'game over'; end if;
  st := r.state; tbl := st->'table'; tr := st->>'trump'; att := (st->>'att')::uuid; def := (st->>'def')::uuid;
  passed := gm_uids(st->'passed'); done_ := gm_uids(st->'done'); lim := coalesce((st->>'limit')::int, 6);
  if me_ = any(done_) then raise exception 'you are out'; end if;
  select cards into h from durak_hands where game_id = g and user_id = me_;
  select left(coalesce(nullif(p.nick, ''), 'Дачник'), 18) into nick from profiles p where id = me_;
  select count(*) into open_ from jsonb_array_elements(tbl) p2 where p2->>1 is null;

  la_ := jsonb_build_object('u', me_, 'a', act, 'c', card, 'i', coalesce((st->'la'->>'i')::int, 0) + 1);

  if act = 'attack' then
    if me_ = def then raise exception 'not your turn'; end if;
    if card is null or not (card = any(h)) then raise exception 'no such card'; end if;
    if jsonb_array_length(tbl) = 0 then
      if me_ <> att then raise exception 'not your turn'; end if;
      lim := least(6, dk_hn(g, def));
    else
      select array_agg(left(x, 1)) into ranks from (select p2->>0 x from jsonb_array_elements(tbl) p2 union all select p2->>1 from jsonb_array_elements(tbl) p2 where p2->>1 is not null) z;
      if not (left(card, 1) = any(ranks)) then raise exception 'rank not on table'; end if;
      if jsonb_array_length(tbl) >= lim or open_ + 1 > dk_hn(g, def) then raise exception 'table full'; end if;
    end if;
    update durak_hands set cards = array_remove(cards, card) where game_id = g and user_id = me_;
    st := st || jsonb_build_object('table', tbl || jsonb_build_array(jsonb_build_array(card, null)), 'limit', lim, 'passed', '[]'::jsonb,
      'log', nick || case when jsonb_array_length(tbl) = 0 then ' ходит ' else ' подкидывает ' end || card);

  elsif act = 'defend' then
    if me_ <> def then raise exception 'not your turn'; end if;
    if card is null or not (card = any(h)) then raise exception 'no such card'; end if;
    if tbl->i is null or (tbl->i)->>1 is not null then raise exception 'bad pair'; end if;
    a_c := (tbl->i)->>0;
    if not ((right(card, 1) = right(a_c, 1) and dk_rank(card) > dk_rank(a_c)) or (right(card, 1) = right(tr, 1) and right(a_c, 1) <> right(tr, 1))) then raise exception 'does not beat'; end if;
    update durak_hands set cards = array_remove(cards, card) where game_id = g and user_id = me_;
    st := st || jsonb_build_object('table', jsonb_set(tbl, array[i::text], jsonb_build_array(a_c, card)), 'log', nick || ' бьёт ' || a_c || ' картой ' || card);

  elsif act = 'take' then
    if me_ <> def or open_ = 0 then raise exception 'not your turn'; end if;
    update world_games set state = st where id = g;
    perform dk_round_end(g, true);
    update world_games set state = jsonb_set(state, '{log}', to_jsonb(nick || ' берёт')) || jsonb_build_object('la', la_) where id = g;
    return;

  elsif act = 'pass' then
    if me_ = def or jsonb_array_length(tbl) = 0 or open_ > 0 then raise exception 'not your turn'; end if;
    if not me_ = any(passed) then passed := passed || me_; end if;
    st := st || jsonb_build_object('passed', to_jsonb(passed));
  else raise exception 'bad action';
  end if;

  update world_games set state = st || jsonb_build_object('la', la_) where id = g;
  perform dk_settle(g);
end $$;
revoke all on function durak_play(uuid, text, text, int) from public, anon;
grant execute on function durak_play(uuid, text, text, int) to authenticated;

create or replace function poker_act(g uuid, act text, amt int default null) returns void language plpgsql security definer set search_path = public as $$
declare r world_games; st jsonb; me_ uuid := auth.uid(); ch jsonb; bet jsonb; ct jsonb; b int; c int; cur int; minr int; need int; x int; to_ int;
        live uuid[]; allin uuid[]; acted uuid[]; nick text; li int;
begin
  select * into r from world_games where id = g for update;
  if not found or r.kind <> 'poker' or not (me_ = any(r.players)) then raise exception 'not your game'; end if;
  if r.status <> 'active' then raise exception 'game over'; end if;
  st := r.state;
  if st->>'street' = 'result' or r.turn is distinct from me_ then raise exception 'not your turn'; end if;
  ch := st->'chips'; bet := coalesce(st->'bet', '{}'); ct := coalesce(st->'contrib', '{}');
  b := gm_int(bet, me_); c := gm_int(ch, me_); cur := coalesce((st->>'cur')::int, 0); minr := coalesce((st->>'minr')::int, 1); need := greatest(0, cur - b);
  live := gm_uids(st->'live'); allin := gm_uids(st->'allin'); acted := gm_uids(st->'acted');
  select left(coalesce(nullif(p.nick, ''), 'Дачник'), 18) into nick from profiles p where id = me_;
  li := coalesce((st->'la'->>'i')::int, 0) + 1;
  if act = 'fold' then
    live := array_remove(live, me_);
    st := st || jsonb_build_object('live', to_jsonb(live), 'log', nick || ' сбросил', 'la', jsonb_build_object('u', me_, 'a', 'fold', 'x', 0, 'i', li));
  elsif act = 'check' then
    if need > 0 then raise exception 'cannot check'; end if;
    acted := acted || me_; st := st || jsonb_build_object('acted', to_jsonb(acted), 'log', nick || ' — чек', 'la', jsonb_build_object('u', me_, 'a', 'check', 'x', 0, 'i', li));
  elsif act in ('call', 'raise', 'allin') then
    if act = 'call' then to_ := b + least(need, c);
    elsif act = 'allin' then to_ := b + c;
    else
      if amt is null then raise exception 'bad amount'; end if;
      to_ := least(amt, b + c);
      if to_ < b + c and (to_ <= cur or to_ < cur + minr) then raise exception 'raise too small'; end if;
    end if;
    if to_ < b then raise exception 'bad amount'; end if;
    x := to_ - b;
    if x = 0 and need > 0 then raise exception 'bad amount'; end if;
    ch := jsonb_set(ch, array[me_::text], to_jsonb(c - x));
    bet := bet || jsonb_build_object(me_::text, to_); ct := ct || jsonb_build_object(me_::text, gm_int(ct, me_) + x);
    if c - x = 0 and not me_ = any(allin) then allin := allin || me_; end if;
    if to_ > cur then
      -- a raise opens the round again for everybody else
      if to_ - cur >= minr then minr := to_ - cur; end if;
      cur := to_; acted := array[me_];
    else acted := acted || me_; end if;
    st := st || jsonb_build_object('chips', ch, 'bet', bet, 'contrib', ct, 'allin', to_jsonb(allin), 'acted', to_jsonb(acted), 'cur', cur, 'minr', minr,
      'la', jsonb_build_object('u', me_, 'a', case when c - x = 0 then 'allin' when to_ > coalesce((r.state->>'cur')::int, 0) then 'raise' when x = 0 then 'check' else 'call' end, 'x', x, 'to', to_, 'i', li),
      'log', nick || case when c - x = 0 then ' — ва-банк ' || to_ when to_ > coalesce((r.state->>'cur')::int, 0) then ' — рейз до ' || to_ when x = 0 then ' — чек' else ' — колл ' || x end);
  else raise exception 'bad action';
  end if;
  update world_games set state = st where id = g;
  perform pk_advance(g, me_);
end $$;
revoke all on function poker_act(uuid, text, int) from public, anon;
grant execute on function poker_act(uuid, text, int) to authenticated;

-- someone leaves «Ривер» (сам или по таймеру): фишки не сгорают — делятся поровну между теми, кто остался, сумма за столом не меняется.
-- Игрок ва-банк (0 фишек, но в раздаче) остаётся за столом до вскрытия.
create or replace function pk_leave(g uuid, u uuid, why text) returns void language plpgsql security definer set search_path = public as $$
declare r world_games; st jsonb; outp uuid[]; seats uuid[]; live uuid[]; ch jsonb; x int; share int; rem int; p uuid;
begin
  select * into r from world_games where id = g;
  st := r.state; outp := gm_uids(st->'out'); if not u = any(outp) then outp := outp || u; end if;
  live := array_remove(gm_uids(st->'live'), u); ch := coalesce(st->'chips', '{}');
  x := gm_int(ch, u); ch := jsonb_set(ch, array[u::text], '0'::jsonb);
  seats := array(select q from unnest(r.players) q where (gm_int(ch, q) > 0 or (q = any(live) and st->>'street' <> 'result')) and not q = any(outp));
  if x > 0 and coalesce(array_length(seats, 1), 0) > 0 then
    share := x / array_length(seats, 1); rem := x - share * array_length(seats, 1);
    foreach p in array seats loop ch := jsonb_set(ch, array[p::text], to_jsonb(gm_int(ch, p) + share + case when p = seats[1] then rem else 0 end)); end loop;
  end if;
  st := st || jsonb_build_object('live', to_jsonb(live), 'out', to_jsonb(outp), 'chips', ch,
    'la', jsonb_build_object('u', u, 'a', 'leave', 'x', 0, 'i', coalesce((st->'la'->>'i')::int, 0) + 1),
    'log', (select left(coalesce(nullif(nick, ''), 'Дачник'), 18) from profiles where id = u) || ' ' || why);
  update world_games set state = st where id = g;
  if coalesce(array_length(seats, 1), 0) <= 1 then
    -- the last one standing takes what is on the table
    if seats[1] is not null then
      update world_games set state = jsonb_set(state || jsonb_build_object('pot', 0, 'bet', '{}'::jsonb), array['chips', seats[1]::text], to_jsonb(gm_int(state->'chips', seats[1]) + coalesce((state->>'pot')::int, 0)
        + (select coalesce(sum(value::int), 0) from jsonb_each_text(coalesce(state->'bet', '{}'))))) || jsonb_build_object('contrib', '{}'::jsonb) where id = g;
    end if;
    perform pk_finish(g, seats[1]); return;
  end if;
  if st->>'street' <> 'result' then perform pk_advance(g, case when r.turn = u then u else null end); end if;
end $$;
revoke all on function pk_leave(uuid, uuid, text) from public, anon, authenticated;
