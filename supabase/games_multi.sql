-- 08.11.2026: онлайн-игры на компанию — «Дурак» на 2–8 человек и «Ривер» (холдем: 2 карты в руке, 5 на столе, фишки).
-- Партия = world_games: players (места по кругу), lobby (кто позван / принял / отказался), opts (стек для «Ривера»).
-- Скрытое остаётся на сервере: колода/борд — durak_deck (без политик), карты на руках — durak_hands (видна только своя).

alter table world_games alter column b drop not null;
alter table world_games add column if not exists players uuid[] not null default '{}';
alter table world_games add column if not exists lobby jsonb not null default '{}';
alter table world_games add column if not exists opts jsonb not null default '{}';
update world_games set players = array[a, b] where players = '{}' and b is not null;
update world_games set lobby = jsonb_build_object(a::text, 'in', b::text, 'invited') where kind = 'durak' and status = 'invite' and lobby = '{}' and b is not null;
create index if not exists world_games_players_idx on world_games using gin (players);
alter table world_games drop constraint if exists world_games_kind_check;
alter table world_games add constraint world_games_kind_check check (kind in ('chess', 'checkers', 'durak', 'poker'));

drop policy if exists "my games" on world_games;
create policy "my games" on world_games for select using (a = auth.uid() or b = auth.uid() or auth.uid() = any(players));

-- the next seat after u (clockwise) among ok
create or replace function gm_next(arr uuid[], u uuid, ok uuid[]) returns uuid language plpgsql immutable as $$
declare n int := coalesce(array_length(arr, 1), 0); i int; k int; x uuid;
begin
  if n = 0 then return null; end if;
  i := coalesce(array_position(arr, u), 0);
  for k in 1..n loop x := arr[((i - 1 + k) % n) + 1]; if x = any(ok) then return x; end if; end loop;
  return null;
end $$;

create or replace function gm_uids(j jsonb) returns uuid[] language sql immutable as $$
  select coalesce(array(select x::uuid from jsonb_array_elements_text(coalesce(j, '[]'::jsonb)) x), '{}')
$$;
create or replace function gm_int(j jsonb, k uuid) returns int language sql immutable as $$ select coalesce((j->>k::text)::int, 0) $$;
create or replace function dk_hn(g uuid, u uuid) returns int language sql stable security definer set search_path = public as $$
  select coalesce((select array_length(cards, 1) from durak_hands where game_id = g and user_id = u), 0)
$$;
create or replace function gm_deck52() returns text[] language sql volatile as $$
  select array_agg(c order by gen_random_uuid()) from (select rk || s as c from unnest(array['2','3','4','5','6','7','8','9','T','J','Q','K','A']) rk, unnest(array['S','H','D','C']) s) x
$$;

/* ============================== lobby ============================== */
-- create a table for a company: me + up to 7 friends; for «Ривер» opts.stack = 300 / 500 / 1000 / 2000
create or replace function game_create(k text, opps uuid[], o jsonb default '{}') returns uuid language plpgsql security definer set search_path = public as $$
declare id_ uuid; me_ uuid := auth.uid(); ps uuid[]; lb jsonb; stack int; u uuid;
begin
  if not has_world() then raise exception 'no access'; end if;
  if k not in ('durak', 'poker') then raise exception 'bad kind'; end if;
  ps := array(select distinct x from unnest(opps) x where x is not null and x <> me_);
  if coalesce(array_length(ps, 1), 0) < 1 then raise exception 'bad opponent'; end if;
  if array_length(ps, 1) > 7 then raise exception 'too many players'; end if;
  if exists (select 1 from unnest(ps) x where not exists (select 1 from profiles where id = x and tg_id is not null)) then raise exception 'bad opponent'; end if;
  if (select count(*) from world_games where a = me_ and status = 'invite' and created_at > now() - interval '1 hour') >= 10 then raise exception 'too many'; end if;
  lb := jsonb_build_object(me_::text, 'in');
  foreach u in array ps loop lb := lb || jsonb_build_object(u::text, 'invited'); end loop;
  stack := coalesce((o->>'stack')::int, 500); if stack not in (300, 500, 1000, 2000) then stack := 500; end if;
  insert into world_games (kind, a, b, players, lobby, opts)
  values (k, me_, case when array_length(ps, 1) = 1 then ps[1] end, array[me_] || ps, lb, case when k = 'poker' then jsonb_build_object('stack', stack) else '{}'::jsonb end)
  returning id into id_;
  return id_;
end $$;

-- start: only those who accepted sit at the table, in their seat order
create or replace function gm_begin(g uuid) returns void language plpgsql security definer set search_path = public as $$
declare r world_games; ps uuid[];
begin
  select * into r from world_games where id = g;
  ps := array(select p from unnest(r.players) with ordinality t(p, i) where r.lobby->>p::text = 'in' order by i);
  if coalesce(array_length(ps, 1), 0) < 2 then
    update world_games set status = 'declined', turn = null, updated_at = now() where id = g; return;
  end if;
  update world_games set players = ps, status = 'active', b = case when array_length(ps, 1) = 2 then ps[2] else null end, updated_at = now() where id = g;
  if r.kind = 'durak' then perform durak_deal(g); else perform pk_start(g); end if;
end $$;
revoke all on function gm_begin(uuid) from public, anon, authenticated;

create or replace function game_answer(g uuid, ok boolean) returns void language plpgsql security definer set search_path = public as $$
declare r world_games; me_ uuid := auth.uid();
begin
  select * into r from world_games where id = g for update;
  if not found or r.status <> 'invite' then raise exception 'not your invite'; end if;
  if r.kind in ('chess', 'checkers') then
    if r.b <> me_ then raise exception 'not your invite'; end if;
    update world_games set status = case when ok then 'active' else 'declined' end, turn = case when ok then r.a else null end, updated_at = now() where id = g;
    return;
  end if;
  if coalesce(r.lobby->>me_::text, '') <> 'invited' then raise exception 'not your invite'; end if;
  update world_games set lobby = lobby || jsonb_build_object(me_::text, case when ok then 'in' else 'declined' end), ver = ver + 1, updated_at = now() where id = g;
  select * into r from world_games where id = g;
  -- everybody answered: start with those who said yes
  if not exists (select 1 from jsonb_each_text(r.lobby) where value = 'invited') then perform gm_begin(g); end if;
end $$;

-- the host starts without waiting for the rest
create or replace function game_start(g uuid) returns void language plpgsql security definer set search_path = public as $$
declare r world_games;
begin
  select * into r from world_games where id = g for update;
  if not found or r.a <> auth.uid() or r.status <> 'invite' or r.kind not in ('durak', 'poker') then raise exception 'not your game'; end if;
  if (select count(*) from jsonb_each_text(r.lobby) where value = 'in') < 2 then raise exception 'need two'; end if;
  perform gm_begin(g);
end $$;

-- call more friends into a table that has not started yet
create or replace function game_add(g uuid, opps uuid[]) returns void language plpgsql security definer set search_path = public as $$
declare r world_games; u uuid; lb jsonb; ps uuid[];
begin
  select * into r from world_games where id = g for update;
  if not found or r.a <> auth.uid() or r.status <> 'invite' or r.kind not in ('durak', 'poker') then raise exception 'not your game'; end if;
  lb := r.lobby; ps := r.players;
  foreach u in array coalesce(opps, '{}') loop
    if u is null or u = any(ps) or not exists (select 1 from profiles where id = u and tg_id is not null) then continue; end if;
    ps := ps || u; lb := lb || jsonb_build_object(u::text, 'invited');
  end loop;
  if array_length(ps, 1) > 8 then raise exception 'too many players'; end if;
  update world_games set players = ps, lobby = lb, ver = ver + 1, updated_at = now() where id = g;
end $$;

/* ============================== «Дурак» на компанию ============================== */
create or replace function durak_deal(g uuid) returns void language plpgsql security definer set search_path = public as $$
declare r world_games; deck text[]; tr text; p uuid; k int := 0; lo int; best int := 99; att uuid; h text[]; hands jsonb := '{}'; n int;
begin
  select * into r from world_games where id = g;
  deck := gm_deck52(); tr := deck[52];   -- the bottom card shows the trump
  delete from durak_hands where game_id = g;
  foreach p in array r.players loop
    h := deck[k * 6 + 1 : k * 6 + 6]; k := k + 1;
    insert into durak_hands values (g, p, h);
    hands := hands || jsonb_build_object(p::text, 6);
    select min(dk_rank(c)) into lo from unnest(h) c where right(c, 1) = right(tr, 1);
    if lo is not null and lo < best then best := lo; att := p; end if;
  end loop;
  deck := deck[k * 6 + 1 : 52]; n := coalesce(array_length(deck, 1), 0);
  att := coalesce(att, r.players[1]);
  insert into durak_deck values (g, deck) on conflict (game_id) do update set cards = excluded.cards;
  update world_games set turn = att, ver = ver + 1, updated_at = now(), state = jsonb_build_object(
    'trump', tr, 'deck', n, 'table', '[]'::jsonb, 'att', att, 'def', gm_next(r.players, att, r.players),
    'hands', hands, 'out', 0, 'done', '[]'::jsonb, 'passed', '[]'::jsonb, 'limit', 6, 'log', 'Раздача: козырь ' || tr) where id = g;
end $$;
revoke all on function durak_deal(uuid) from public, anon, authenticated;

-- can u still throw a card into the current round?
create or replace function dk_can_throw(g uuid, u uuid, st jsonb) returns boolean language plpgsql stable security definer set search_path = public as $$
declare tbl jsonb := st->'table'; def uuid := (st->>'def')::uuid; open_ int; h text[];
begin
  if u = def or jsonb_array_length(tbl) = 0 then return false; end if;
  if jsonb_array_length(tbl) >= coalesce((st->>'limit')::int, 6) then return false; end if;
  select count(*) into open_ from jsonb_array_elements(tbl) p where p->>1 is null;
  if open_ + 1 > dk_hn(g, def) then return false; end if;
  select cards into h from durak_hands where game_id = g and user_id = u;
  return exists (select 1 from unnest(h) c where left(c, 1) in (select left(x, 1) from (select p->>0 x from jsonb_array_elements(tbl) p union all select p->>1 from jsonb_array_elements(tbl) p where p->>1 is not null) z));
end $$;
revoke all on function dk_can_throw(uuid, uuid, jsonb) from public, anon, authenticated;

-- the round is over: take or «бито», draw cards, who is out, who attacks next, end of the game
create or replace function dk_round_end(g uuid, took boolean) returns void language plpgsql security definer set search_path = public as $$
declare r world_games; st jsonb; tbl jsonb; att uuid; def uuid; deck text[]; done_ uuid[]; act_ uuid[]; ord uuid[]; p uuid; h text[]; need int;
        hands jsonb := '{}'; na uuid; nd uuid; tc text[]; los uuid;
begin
  select * into r from world_games where id = g;
  st := r.state; tbl := st->'table'; att := (st->>'att')::uuid; def := (st->>'def')::uuid; done_ := gm_uids(st->'done');
  tc := array(select p2->>0 from jsonb_array_elements(tbl) p2 union all select p2->>1 from jsonb_array_elements(tbl) p2 where p2->>1 is not null);
  if took then update durak_hands set cards = durak_hands.cards || tc where game_id = g and user_id = def;
  else st := jsonb_set(st, '{out}', to_jsonb(coalesce((st->>'out')::int, 0) + coalesce(array_length(tc, 1), 0))); end if;
  -- draw up to six: the attacker first, then clockwise, the defender last
  act_ := array(select x from unnest(r.players) x where not x = any(done_));
  ord := array[att];
  p := att;
  loop p := gm_next(r.players, p, act_); exit when p is null or p = att; if p <> def then ord := ord || p; end if; end loop;
  if def <> att then ord := ord || def; end if;
  select cards into deck from durak_deck where game_id = g;
  foreach p in array ord loop
    select cards into h from durak_hands where game_id = g and user_id = p;
    need := greatest(0, 6 - coalesce(array_length(h, 1), 0));
    if need > 0 and coalesce(array_length(deck, 1), 0) > 0 then
      h := coalesce(h, '{}') || deck[1:need]; deck := coalesce(deck[need + 1:], '{}');
      update durak_hands set cards = h where game_id = g and user_id = p;
    end if;
  end loop;
  update durak_deck set cards = coalesce(deck, '{}') where game_id = g;
  -- nobody draws any more: whoever has no cards is out (and safe)
  if coalesce(array_length(deck, 1), 0) = 0 then
    foreach p in array r.players loop
      if not p = any(done_) and dk_hn(g, p) = 0 then done_ := done_ || p; end if;
    end loop;
  end if;
  act_ := array(select x from unnest(r.players) x where not x = any(done_));
  foreach p in array r.players loop hands := hands || jsonb_build_object(p::text, dk_hn(g, p)); end loop;
  st := st || jsonb_build_object('table', '[]'::jsonb, 'passed', '[]'::jsonb, 'done', to_jsonb(done_), 'hands', hands,
    'deck', coalesce(array_length(deck, 1), 0), 'log', case when took then 'Взял карты' else 'Бито' end);
  if coalesce(array_length(act_, 1), 0) <= 1 then
    los := act_[1];
    st := st || jsonb_build_object('loser', los);
    update world_games set state = st, status = 'done', result = case when los is null then 'draw' else 'durak' end,
      winner = done_[1], turn = null, ver = ver + 1, updated_at = now() where id = g;
    foreach p in array r.players loop perform world_xp(p, case when los is null then 15 when p = los then 10 else 20 end); end loop;
    return;
  end if;
  if took then na := gm_next(r.players, def, act_);
  else na := case when def = any(act_) then def else gm_next(r.players, def, act_) end; end if;
  nd := gm_next(r.players, na, act_);
  st := st || jsonb_build_object('att', na, 'def', nd, 'limit', least(6, dk_hn(g, nd)));
  update world_games set state = st, turn = na, ver = ver + 1, updated_at = now() where id = g;
end $$;
revoke all on function dk_round_end(uuid, boolean) from public, anon, authenticated;

-- after every move: close the round when nobody can or wants to throw more; otherwise say whose move it is
create or replace function dk_settle(g uuid) returns void language plpgsql security definer set search_path = public as $$
declare r world_games; st jsonb; tbl jsonb; open_ int; att uuid; def uuid; passed uuid[]; done_ uuid[]; act_ uuid[]; p uuid; who uuid; hands jsonb := '{}';
begin
  select * into r from world_games where id = g;
  if r.status <> 'active' then return; end if;
  st := r.state; tbl := st->'table'; att := (st->>'att')::uuid; def := (st->>'def')::uuid;
  passed := gm_uids(st->'passed'); done_ := gm_uids(st->'done');
  act_ := array(select x from unnest(r.players) x where not x = any(done_));
  select count(*) into open_ from jsonb_array_elements(tbl) p2 where p2->>1 is null;
  foreach p in array r.players loop hands := hands || jsonb_build_object(p::text, dk_hn(g, p)); end loop;
  st := st || jsonb_build_object('hands', hands);
  if open_ > 0 then who := def;
  elsif jsonb_array_length(tbl) = 0 then who := att;
  else
    -- everything is beaten: the attacker first, then clockwise, whoever still can throw and has not passed
    p := att;
    for i in 1..coalesce(array_length(r.players, 1), 0) loop
      if p = any(act_) and not p = any(passed) and dk_can_throw(g, p, st) then who := p; exit; end if;
      p := gm_next(r.players, p, r.players);
    end loop;
    if who is null then update world_games set state = st where id = g; perform dk_round_end(g, false); return; end if;
  end if;
  update world_games set state = st, turn = who, ver = ver + 1, updated_at = now() where id = g;
end $$;
revoke all on function dk_settle(uuid) from public, anon, authenticated;

-- one action: 'attack' (lead or throw in) · 'defend' a card onto pair i · 'take' · 'pass' (бито / не подкидываю)
create or replace function durak_play(g uuid, act text, card text default null, i int default null)
returns void language plpgsql security definer set search_path = public as $$
declare r world_games; st jsonb; tbl jsonb; h text[]; tr text; att uuid; def uuid; me_ uuid := auth.uid();
        ranks text[]; open_ int; a_c text; lim int; passed uuid[]; done_ uuid[]; nick text;
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
    update world_games set state = jsonb_set(state, '{log}', to_jsonb(nick || ' берёт')) where id = g;
    return;

  elsif act = 'pass' then
    if me_ = def or jsonb_array_length(tbl) = 0 or open_ > 0 then raise exception 'not your turn'; end if;
    if not me_ = any(passed) then passed := passed || me_; end if;
    st := st || jsonb_build_object('passed', to_jsonb(passed));
  else raise exception 'bad action';
  end if;

  update world_games set state = st where id = g;
  perform dk_settle(g);
end $$;
revoke all on function durak_play(uuid, text, text, int) from public, anon;
grant execute on function durak_play(uuid, text, text, int) to authenticated;

/* ============================== «Ривер» (холдем) ============================== */
-- the score of five cards: category * 15^5 + kickers (bigger is better)
create or replace function pk_score5(c text[]) returns bigint language plpgsql immutable as $$
declare rk int[]; fl boolean; st boolean; hi int; grp int[]; cnt int[]; cat int; sc bigint := 0; x int;
begin
  rk := array(select position(left(v, 1) in '23456789TJQKA') + 1 from unnest(c) v order by 1 desc);
  fl := (select count(distinct right(v, 1)) from unnest(c) v) = 1;
  st := (select count(distinct v) from unnest(rk) v) = 5 and (rk[1] - rk[5] = 4 or rk = array[14, 5, 4, 3, 2]);
  hi := case when rk = array[14, 5, 4, 3, 2] then 5 else rk[1] end;
  select array_agg(v order by n desc, v desc), array_agg(n order by n desc, v desc) into grp, cnt
    from (select v, count(*) n from unnest(rk) v group by v) z;
  cat := case when st and fl then 8 when cnt[1] = 4 then 7 when cnt[1] = 3 and cnt[2] = 2 then 6 when fl then 5 when st then 4
              when cnt[1] = 3 then 3 when cnt[1] = 2 and cnt[2] = 2 then 2 when cnt[1] = 2 then 1 else 0 end;
  if cat in (8, 4) then return cat::bigint * 759375 + hi; end if;
  foreach x in array grp loop sc := sc * 15 + x; end loop;
  for x in 1..(5 - array_length(grp, 1)) loop sc := sc * 15; end loop;
  return cat::bigint * 759375 + sc;
end $$;
-- the best five out of seven
create or replace function pk_best(c text[]) returns bigint language plpgsql immutable as $$
declare n int := array_length(c, 1); best bigint := -1; s bigint; i int; j int; f text[];
begin
  if n <= 5 then return pk_score5(c); end if;
  for i in 1..n - 1 loop for j in i + 1..n loop
    f := array(select c[k] from generate_series(1, n) k where k <> i and k <> j);
    if n = 7 then s := pk_score5(f); else s := pk_best(f); end if;
    if s > best then best := s; end if;
  end loop; end loop;
  return best;
end $$;
create or replace function pk_name(s bigint) returns text language sql immutable as $$
  select case s / 759375 when 8 then case when s % 759375 = 14 then 'Роял-флеш' else 'Стрит-флеш' end when 7 then 'Каре' when 6 then 'Фулл-хаус' when 5 then 'Флеш'
    when 4 then 'Стрит' when 3 then 'Сет' when 2 then 'Две пары' when 1 then 'Пара' else 'Старшая карта' end
$$;

-- first hand of the table
create or replace function pk_start(g uuid) returns void language plpgsql security definer set search_path = public as $$
declare r world_games; ch jsonb := '{}'; p uuid; stack int;
begin
  select * into r from world_games where id = g;
  stack := coalesce((r.opts->>'stack')::int, 500);
  foreach p in array r.players loop ch := ch || jsonb_build_object(p::text, stack); end loop;
  update world_games set state = jsonb_build_object('chips', ch, 'hand', 0, 'out', '[]'::jsonb, 'stack', stack, 'base', greatest(1, stack / 100)) where id = g;
  perform pk_deal(g);
end $$;
revoke all on function pk_start(uuid) from public, anon, authenticated;

-- a new hand: move the button, post the blinds, two cards each, five hidden for the board
create or replace function pk_deal(g uuid) returns void language plpgsql security definer set search_path = public as $$
declare r world_games; st jsonb; ch jsonb; seats uuid[]; outp uuid[]; dealer uuid; sbp uuid; bbp uuid; sb int; bb int; hand int; deck text[]; k int := 0; p uuid;
        bet jsonb := '{}'; allin uuid[] := '{}'; x int; canact uuid[]; first_ uuid;
begin
  select * into r from world_games where id = g;
  st := r.state; ch := st->'chips'; outp := gm_uids(st->'out');
  seats := array(select q from unnest(r.players) q where gm_int(ch, q) > 0 and not q = any(outp));
  if coalesce(array_length(seats, 1), 0) <= 1 then perform pk_finish(g, seats[1]); return; end if;
  hand := coalesce((st->>'hand')::int, 0) + 1;
  dealer := gm_next(r.players, (st->>'dealer')::uuid, seats);
  sb := coalesce((st->>'base')::int, 5) * (1 << least(6, (hand - 1) / 10)); bb := sb * 2;   -- blinds double every 10 hands
  if array_length(seats, 1) = 2 then sbp := dealer; bbp := gm_next(r.players, dealer, seats);
  else sbp := gm_next(r.players, dealer, seats); bbp := gm_next(r.players, sbp, seats); end if;
  deck := gm_deck52();
  delete from durak_hands where game_id = g;
  foreach p in array seats loop insert into durak_hands values (g, p, deck[k * 2 + 1 : k * 2 + 2]); k := k + 1; end loop;
  insert into durak_deck values (g, deck[k * 2 + 1 : k * 2 + 5]) on conflict (game_id) do update set cards = excluded.cards;
  x := least(sb, gm_int(ch, sbp)); ch := jsonb_set(ch, array[sbp::text], to_jsonb(gm_int(ch, sbp) - x)); bet := bet || jsonb_build_object(sbp::text, x);
  x := least(bb, gm_int(ch, bbp)); ch := jsonb_set(ch, array[bbp::text], to_jsonb(gm_int(ch, bbp) - x)); bet := bet || jsonb_build_object(bbp::text, x);
  foreach p in array seats loop if gm_int(ch, p) = 0 then allin := allin || p; end if; end loop;
  canact := array(select q from unnest(seats) q where not q = any(allin));
  first_ := case when array_length(seats, 1) = 2 then dealer else gm_next(r.players, bbp, canact) end;
  if first_ = any(allin) then first_ := gm_next(r.players, first_, canact); end if;
  st := st || jsonb_build_object('hand', hand, 'dealer', dealer, 'sbp', sbp, 'bbp', bbp, 'sb', sb, 'bb', bb, 'chips', ch, 'bet', bet, 'contrib', bet,
    'live', to_jsonb(seats), 'allin', to_jsonb(allin), 'acted', '[]'::jsonb, 'cur', bb, 'minr', bb, 'pot', 0, 'board', '[]'::jsonb,
    'street', 'pre', 'seats', to_jsonb(seats), 'log', 'Раздача №' || hand || ' · блайнды ' || sb || '/' || bb);
  update world_games set state = st, turn = first_, ver = ver + 1, updated_at = now() where id = g;
  perform pk_advance(g, null);
end $$;
revoke all on function pk_deal(uuid) from public, anon, authenticated;

-- the table is won (or everybody but one left)
create or replace function pk_finish(g uuid, w uuid) returns void language plpgsql security definer set search_path = public as $$
declare r world_games; p uuid;
begin
  select * into r from world_games where id = g;
  update world_games set status = 'done', result = case when w is null then 'draw' else 'win' end, winner = w, turn = null, ver = ver + 1, updated_at = now() where id = g;
  foreach p in array r.players loop perform world_xp(p, case when p = w then 30 else 10 end); end loop;
end $$;
revoke all on function pk_finish(uuid, uuid) from public, anon, authenticated;

-- money from the pot to the winners, side pots included; then the result stays on the table for a few seconds
create or replace function pk_showdown(g uuid) returns void language plpgsql security definer set search_path = public as $$
declare r world_games; st jsonb; live uuid[]; ch jsonb; ct jsonb; board text[]; sc jsonb := '{}'; shown jsonb := '{}'; h text[]; p uuid; s bigint;
        lv int; prev int := 0; portion int; elig uuid[]; best bigint; wins uuid[]; share int; rem int; won jsonb := '{}'; lst jsonb := '[]'; seats uuid[]; outp uuid[];
begin
  select * into r from world_games where id = g;
  st := r.state; live := gm_uids(st->'live'); ch := st->'chips'; ct := st->'contrib';
  select cards into board from durak_deck where game_id = g;
  if array_length(live, 1) = 1 then
    -- everybody else folded: no cards shown, the whole pot goes to the last one
    portion := (select coalesce(sum(value::int), 0) from jsonb_each_text(ct));
    won := jsonb_build_object(live[1]::text, portion);
    st := st || jsonb_build_object('board', st->'board');
  else
    foreach p in array live loop
      select cards into h from durak_hands where game_id = g and user_id = p;
      s := pk_best(h || board); sc := sc || jsonb_build_object(p::text, s); shown := shown || jsonb_build_object(p::text, to_jsonb(h));
    end loop;
    for lv in select distinct gm_int(ct, q) from unnest(live) q order by 1 loop
      portion := (select coalesce(sum(least(value::int, lv) - least(value::int, prev)), 0) from jsonb_each_text(ct));
      elig := array(select q from unnest(live) q where gm_int(ct, q) >= lv);
      best := (select max((sc->>q::text)::bigint) from unnest(elig) q);
      -- winners in seat order after the button (the odd chip goes to the first of them)
      wins := '{}'; p := (st->>'dealer')::uuid;
      for k in 1..array_length(r.players, 1) loop p := gm_next(r.players, p, r.players);
        if p = any(elig) and (sc->>p::text)::bigint = best then wins := wins || p; end if; end loop;
      share := portion / array_length(wins, 1); rem := portion - share * array_length(wins, 1);
      foreach p in array wins loop won := won || jsonb_build_object(p::text, gm_int(won, p) + share + case when p = wins[1] then rem else 0 end); end loop;
      prev := lv;
    end loop;
    st := st || jsonb_build_object('board', to_jsonb(board));
  end if;
  for p in select key::uuid from jsonb_each_text(won) loop
    ch := jsonb_set(ch, array[p::text], to_jsonb(gm_int(ch, p) + gm_int(won, p)));
    lst := lst || jsonb_build_array(jsonb_build_object('u', p, 'amt', gm_int(won, p), 'name', case when sc ? p::text then pk_name((sc->>p::text)::bigint) end));
  end loop;
  outp := gm_uids(st->'out');
  foreach p in array gm_uids(st->'seats') loop if gm_int(ch, p) = 0 and not p = any(outp) then outp := outp || p; end if; end loop;
  st := st || jsonb_build_object('chips', ch, 'bet', '{}'::jsonb, 'pot', 0, 'street', 'result', 'out', to_jsonb(outp), 'acted', '[]'::jsonb,
    'last', jsonb_build_object('hand', st->'hand', 'wins', lst, 'shown', shown, 'board', st->'board'),
    'log', (select string_agg(left(coalesce(nullif(pr.nick, ''), 'Дачник'), 18) || ' +' || (x->>'amt') || coalesce(' · ' || (x->>'name'), ''), ', ')
            from jsonb_array_elements(lst) x join profiles pr on pr.id = (x->>'u')::uuid));
  update world_games set state = st, turn = null, ver = ver + 1, updated_at = now() where id = g;
  seats := array(select q from unnest(r.players) q where gm_int(ch, q) > 0 and not q = any(outp));
  if coalesce(array_length(seats, 1), 0) <= 1 then perform pk_finish(g, seats[1]); end if;
end $$;
revoke all on function pk_showdown(uuid) from public, anon, authenticated;

-- move the game on: next player, next street, the board, the showdown
create or replace function pk_advance(g uuid, from_ uuid) returns void language plpgsql security definer set search_path = public as $$
declare r world_games; st jsonb; live uuid[]; allin uuid[]; acted uuid[]; canact uuid[]; bet jsonb; cur int; done_ boolean; p uuid; nxt uuid; street text;
        board jsonb; fullb text[]; pot int;
begin
  loop
    select * into r from world_games where id = g;
    st := r.state; live := gm_uids(st->'live'); allin := gm_uids(st->'allin'); acted := gm_uids(st->'acted'); bet := coalesce(st->'bet', '{}');
    cur := coalesce((st->>'cur')::int, 0); street := st->>'street';
    if array_length(live, 1) = 1 then
      update world_games set state = st || jsonb_build_object('pot', coalesce((st->>'pot')::int, 0) + (select coalesce(sum(value::int), 0) from jsonb_each_text(bet)), 'bet', '{}'::jsonb) where id = g;
      perform pk_showdown(g); return;
    end if;
    canact := array(select q from unnest(live) q where not q = any(allin));
    if coalesce(array_length(canact, 1), 0) = 0 then done_ := true;
    elsif array_length(canact, 1) = 1 and gm_int(bet, canact[1]) >= cur and (canact[1] = any(acted) or cur = 0 or (select max(gm_int(bet, q)) from unnest(live) q) <= gm_int(bet, canact[1])) then done_ := true;
    else done_ := not exists (select 1 from unnest(canact) q where not q = any(acted) or gm_int(bet, q) < cur);
    end if;
    if not done_ then
      -- the next one who still has to act, clockwise from the last mover
      nxt := null; p := coalesce(from_, r.turn);
      for k in 1..array_length(r.players, 1) loop
        p := gm_next(r.players, p, canact);
        if p is not null and (not p = any(acted) or gm_int(bet, p) < cur) then nxt := p; exit; end if;
      end loop;
      if from_ is null and r.turn is not null and r.turn = any(canact) and (not r.turn = any(acted) or gm_int(bet, r.turn) < cur) then nxt := r.turn; end if;
      update world_games set turn = nxt, ver = ver + 1, updated_at = now() where id = g;
      return;
    end if;
    -- the street is over: bets go to the pot
    pot := coalesce((st->>'pot')::int, 0) + (select coalesce(sum(value::int), 0) from jsonb_each_text(bet));
    select cards into fullb from durak_deck where game_id = g;
    if street = 'river' then
      update world_games set state = st || jsonb_build_object('pot', pot, 'bet', '{}'::jsonb) where id = g;
      perform pk_showdown(g); return;
    end if;
    street := case street when 'pre' then 'flop' when 'flop' then 'turn' else 'river' end;
    board := to_jsonb(fullb[1 : case street when 'flop' then 3 when 'turn' then 4 else 5 end]);
    st := st || jsonb_build_object('pot', pot, 'bet', '{}'::jsonb, 'acted', '[]'::jsonb, 'cur', 0, 'minr', st->'bb', 'street', street, 'board', board,
      'log', case street when 'flop' then 'Флоп' when 'turn' then 'Тёрн' else 'Ривер' end);
    update world_games set state = st where id = g;
    if coalesce(array_length(canact, 1), 0) <= 1 then continue; end if;   -- all-in: open the board to the end
    nxt := gm_next(r.players, (st->>'dealer')::uuid, canact);
    update world_games set turn = nxt, ver = ver + 1, updated_at = now() where id = g;
    return;
  end loop;
end $$;
revoke all on function pk_advance(uuid, uuid) from public, anon, authenticated;

-- one action: fold · check · call · raise (amt = how much my bet becomes) · allin
create or replace function poker_act(g uuid, act text, amt int default null) returns void language plpgsql security definer set search_path = public as $$
declare r world_games; st jsonb; me_ uuid := auth.uid(); ch jsonb; bet jsonb; ct jsonb; b int; c int; cur int; minr int; need int; x int; to_ int;
        live uuid[]; allin uuid[]; acted uuid[]; nick text;
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
  if act = 'fold' then
    live := array_remove(live, me_);
    st := st || jsonb_build_object('live', to_jsonb(live), 'log', nick || ' сбросил');
  elsif act = 'check' then
    if need > 0 then raise exception 'cannot check'; end if;
    acted := acted || me_; st := st || jsonb_build_object('acted', to_jsonb(acted), 'log', nick || ' — чек');
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
      'log', nick || case when c - x = 0 then ' — ва-банк ' || to_ when to_ > coalesce((r.state->>'cur')::int, 0) then ' — рейз до ' || to_ when x = 0 then ' — чек' else ' — колл ' || x end);
  else raise exception 'bad action';
  end if;
  update world_games set state = st where id = g;
  perform pk_advance(g, me_);
end $$;
revoke all on function poker_act(uuid, text, int) from public, anon;
grant execute on function poker_act(uuid, text, int) to authenticated;

-- after a result has been on the table for a few seconds anybody at the table deals the next hand
create or replace function poker_next(g uuid) returns boolean language plpgsql security definer set search_path = public as $$
declare r world_games;
begin
  select * into r from world_games where id = g for update;
  if not found or r.kind <> 'poker' or not (auth.uid() = any(r.players)) or r.status <> 'active' then return false; end if;
  if r.state->>'street' <> 'result' or r.updated_at > now() - interval '4 seconds' then return false; end if;
  perform pk_deal(g);
  return true;
end $$;
revoke all on function poker_next(uuid) from public, anon;
grant execute on function poker_next(uuid) to authenticated;

/* ============================== resign / timeout for every kind ============================== */
create or replace function game_resign(g uuid) returns void language plpgsql security definer set search_path = public as $$
declare r world_games; w uuid; me_ uuid := auth.uid(); st jsonb; p uuid; outp uuid[]; seats uuid[];
begin
  select * into r from world_games where id = g for update;
  if not found or not (me_ = r.a or me_ = r.b or me_ = any(r.players)) or r.status not in ('active', 'invite') then raise exception 'not your game'; end if;
  if r.status = 'invite' then
    if r.kind in ('chess', 'checkers') or me_ = r.a then update world_games set status = 'declined', updated_at = now() where id = g; return; end if;
    -- a guest leaves the lobby (invited or already seated)
    update world_games set lobby = lobby || jsonb_build_object(me_::text, 'declined'), ver = ver + 1, updated_at = now() where id = g;
    if not exists (select 1 from jsonb_each_text((select lobby from world_games where id = g)) where value = 'invited') then perform gm_begin(g); end if;
    return;
  end if;
  if r.kind in ('chess', 'checkers') then
    w := case when me_ = r.a then r.b else r.a end;
    update world_games set status = 'done', result = 'resign', winner = w, turn = null, ver = ver + 1, updated_at = now() where id = g;
    perform world_xp(w, 30); perform world_xp(me_, 5); return;
  end if;
  if r.kind = 'durak' then
    -- whoever leaves the durak table is the durak
    update world_games set status = 'done', result = 'resign', state = state || jsonb_build_object('loser', me_),
      winner = (select q from unnest(r.players) q where q <> me_ limit 1), turn = null, ver = ver + 1, updated_at = now() where id = g;
    foreach p in array r.players loop perform world_xp(p, case when p = me_ then 5 else 20 end); end loop;
    return;
  end if;
  -- «Ривер»: you fold and leave the table, your chips stay out of the game
  st := r.state; outp := gm_uids(st->'out'); if not me_ = any(outp) then outp := outp || me_; end if;
  st := st || jsonb_build_object('live', to_jsonb(array_remove(gm_uids(st->'live'), me_)), 'out', to_jsonb(outp), 'chips', jsonb_set(st->'chips', array[me_::text], '0'::jsonb),
    'log', (select left(coalesce(nullif(nick, ''), 'Дачник'), 18) from profiles where id = me_) || ' ушёл из-за стола');
  update world_games set state = st where id = g;
  seats := array(select q from unnest(r.players) q where gm_int(st->'chips', q) > 0 and not q = any(outp));
  if coalesce(array_length(seats, 1), 0) <= 1 then
    -- the last one standing takes what is on the table
    if seats[1] is not null then
      update world_games set state = jsonb_set(state, array['chips', seats[1]::text], to_jsonb(gm_int(state->'chips', seats[1]) + coalesce((state->>'pot')::int, 0)
        + (select coalesce(sum(value::int), 0) from jsonb_each_text(coalesce(state->'bet', '{}'))))) where id = g;
    end if;
    perform pk_finish(g, seats[1]); return;
  end if;
  if st->>'street' <> 'result' then perform pk_advance(g, case when r.turn = me_ then me_ else null end); end if;
end $$;

-- a move that hangs for 5 minutes: chess/checkers — loss; durak — the stuck defender/leader is the durak, a thrower just passes; «Ривер» — auto check / fold
create or replace function game_timeout(g uuid) returns boolean language plpgsql security definer set search_path = public as $$
declare r world_games; w uuid; st jsonb; t uuid; p uuid;
begin
  select * into r from world_games where id = g for update;
  if not found or not (auth.uid() = r.a or auth.uid() = r.b or auth.uid() = any(r.players)) or r.status <> 'active' then return false; end if;
  if r.kind = 'poker' and r.state->>'street' = 'result' then
    if r.updated_at > now() - interval '4 seconds' then return false; end if;
    perform pk_deal(g); return true;
  end if;
  if r.turn is null or r.updated_at > now() - interval '5 minutes' then return false; end if;
  t := r.turn; st := r.state;
  if r.kind in ('chess', 'checkers') then
    w := case when t = r.a then r.b else r.a end;
    update world_games set status = 'done', result = 'timeout', winner = w, turn = null, ver = ver + 1, updated_at = now() where id = g;
    perform world_xp(w, 30); perform world_xp(case when w = r.a then r.b else r.a end, 5);
  elsif r.kind = 'durak' then
    if t = (st->>'def')::uuid or jsonb_array_length(st->'table') = 0 then
      update world_games set status = 'done', result = 'timeout', state = state || jsonb_build_object('loser', t),
        winner = (select q from unnest(r.players) q where q <> t limit 1), turn = null, ver = ver + 1, updated_at = now() where id = g;
      foreach p in array r.players loop perform world_xp(p, case when p = t then 5 else 20 end); end loop;
    else
      update world_games set state = state || jsonb_build_object('passed', coalesce(state->'passed', '[]'::jsonb) || to_jsonb(t::text)) where id = g;
      perform dk_settle(g);
    end if;
  else
    if gm_int(st->'bet', t) >= coalesce((st->>'cur')::int, 0) then
      st := st || jsonb_build_object('acted', coalesce(st->'acted', '[]'::jsonb) || to_jsonb(t::text), 'log', 'Время вышло — чек');
    else
      st := st || jsonb_build_object('live', to_jsonb(array_remove(gm_uids(st->'live'), t)), 'log', 'Время вышло — сброс');
    end if;
    update world_games set state = st where id = g;
    perform pk_advance(g, t);
  end if;
  return true;
end $$;

-- the game chat: everybody at the table can write; for a company the message goes to the host's address (others read it by game)
create or replace function dm_send(to_ uuid, body_ text, g uuid) returns uuid language plpgsql security definer set search_path = public as $$
declare id_ uuid; t text := left(trim(body_), 1000);
begin
  if t = '' then raise exception 'empty'; end if;
  if not exists (select 1 from world_games where id = g and ((a = auth.uid() and b = to_) or (b = auth.uid() and a = to_)
       or (auth.uid() = any(players) and to_ = any(players) and to_ <> auth.uid()))) then raise exception 'not your game'; end if;
  if (select count(*) from dm_messages where from_id = auth.uid() and created_at > now() - interval '1 minute') >= 30 then raise exception 'too fast'; end if;
  insert into dm_messages (from_id, to_id, body, game_id) values (auth.uid(), to_, t, g) returning id into id_;
  return id_;
end $$;

grant execute on function game_create(text, uuid[], jsonb), game_start(uuid), game_add(uuid, uuid[]) to authenticated;
revoke all on function game_create(text, uuid[], jsonb), game_start(uuid), game_add(uuid, uuid[]) from public, anon;

-- the old «позвать одного» path for durak / «Ривер» goes through the company lobby
create or replace function game_invite(k text, opp uuid) returns uuid language plpgsql security definer set search_path = public as $$
declare id_ uuid;
begin
  if k in ('durak', 'poker') then return game_create(k, array[opp], '{}'); end if;
  if not has_world() then raise exception 'no access'; end if;
  if opp is null or opp = auth.uid() or not exists (select 1 from profiles where id = opp and tg_id is not null) then raise exception 'bad opponent'; end if;
  if (select count(*) from world_games where a = auth.uid() and status = 'invite' and created_at > now() - interval '1 hour') >= 10 then raise exception 'too many'; end if;
  insert into world_games (kind, a, b, players) values (k, auth.uid(), opp, array[auth.uid(), opp]) returning id into id_;
  return id_;
end $$;
