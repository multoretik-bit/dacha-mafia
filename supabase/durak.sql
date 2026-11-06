-- DACHA WORLD: «Дурак» (подкидной, на двоих) — 06.11.
-- Cards: rank + suit, ranks 6 7 8 9 T J Q K A, suits S H D C ("TH" = 10♥). 36 cards, 6 in hand, the last card is the trump.
-- Hidden information stays on the server: the deck is in durak_deck (nobody reads it), each hand in durak_hands (only its owner).
-- world_games.state is public: trump, deck size, table pairs, who attacks, hand sizes, discard size.

alter table world_games drop constraint if exists world_games_kind_check;
alter table world_games add constraint world_games_kind_check check (kind in ('chess', 'checkers', 'durak'));

create table if not exists durak_deck (game_id uuid primary key references world_games(id) on delete cascade, cards text[] not null);
alter table durak_deck enable row level security;            -- no policies: only the functions below
create table if not exists durak_hands (game_id uuid references world_games(id) on delete cascade, user_id uuid references profiles(id) on delete cascade, cards text[] not null default '{}', primary key (game_id, user_id));
alter table durak_hands enable row level security;
drop policy if exists "my hand" on durak_hands;
create policy "my hand" on durak_hands for select using (user_id = auth.uid());

create or replace function dk_rank(c text) returns int language sql immutable as $$ select position(left(c, 1) in '6789TJQKA') $$;

-- deal: shuffle, 6 each, trump = bottom card; the lowest trump attacks first
create or replace function durak_deal(g uuid) returns void language plpgsql security definer set search_path = public as $$
declare r world_games; deck text[]; ha text[]; hb text[]; tr text; att uuid; la int; lb int;
begin
  select * into r from world_games where id = g;
  select array_agg(c order by random()) into deck from (select rk || s as c from unnest(array['6','7','8','9','T','J','Q','K','A']) rk, unnest(array['S','H','D','C']) s) x;
  ha := deck[1:6]; hb := deck[7:12]; deck := deck[13:36];
  tr := deck[array_length(deck, 1)];
  select min(dk_rank(c)) into la from unnest(ha) c where right(c, 1) = right(tr, 1);
  select min(dk_rank(c)) into lb from unnest(hb) c where right(c, 1) = right(tr, 1);
  att := case when lb is not null and (la is null or lb < la) then r.b else r.a end;
  insert into durak_deck values (g, deck) on conflict (game_id) do update set cards = excluded.cards;
  insert into durak_hands values (g, r.a, ha), (g, r.b, hb) on conflict (game_id, user_id) do update set cards = excluded.cards;
  update world_games set turn = att, ver = ver + 1, updated_at = now(), state = jsonb_build_object(
    'trump', tr, 'deck', 24, 'table', '[]'::jsonb, 'att', att, 'def', case when att = r.a then r.b else r.a end,
    'hands', jsonb_build_object(r.a::text, 6, r.b::text, 6), 'out', 0, 'log', 'Раздача: козырь ' || tr) where id = g;
end $$;
revoke all on function durak_deal(uuid) from public, anon, authenticated;

-- refill after a round: the attacker draws first, then the defender
create or replace function dk_refill(g uuid, first_ uuid, second_ uuid) returns void language plpgsql security definer set search_path = public as $$
declare deck text[]; h text[]; need int; u uuid;
begin
  select cards into deck from durak_deck where game_id = g;
  foreach u in array array[first_, second_] loop
    select cards into h from durak_hands where game_id = g and user_id = u;
    need := greatest(0, 6 - coalesce(array_length(h, 1), 0));
    if need > 0 and coalesce(array_length(deck, 1), 0) > 0 then
      h := h || deck[1:need]; deck := deck[need + 1:];
      update durak_hands set cards = h where game_id = g and user_id = u;
    end if;
  end loop;
  update durak_deck set cards = coalesce(deck, '{}') where game_id = g;
end $$;
revoke all on function dk_refill(uuid, uuid, uuid) from public, anon, authenticated;

-- one action: 'attack' a card · 'defend' a card onto table pair i · 'take' (defender takes the table) · 'done' (бито)
create or replace function durak_play(g uuid, act text, card text default null, i int default null)
returns void language plpgsql security definer set search_path = public as $$
declare r world_games; st jsonb; tbl jsonb; h text[]; tr text; att uuid; def uuid; me_ uuid := auth.uid();
        ranks text[]; open_ int; dh int; pair jsonb; a_c text; deckn int; ha int; hb int; w uuid;
begin
  select * into r from world_games where id = g for update;
  if not found or me_ not in (r.a, r.b) or r.kind <> 'durak' then raise exception 'not your game'; end if;
  if r.status <> 'active' then raise exception 'game over'; end if;
  st := r.state; tbl := st->'table'; tr := st->>'trump'; att := (st->>'att')::uuid; def := (st->>'def')::uuid;
  select cards into h from durak_hands where game_id = g and user_id = me_;

  if act = 'attack' then
    if me_ <> att or r.turn <> me_ then raise exception 'not your turn'; end if;
    if card is null or not (card = any(h)) then raise exception 'no such card'; end if;
    if jsonb_array_length(tbl) > 0 then
      select array_agg(left(x, 1)) into ranks from (select p->>0 x from jsonb_array_elements(tbl) p union all select p->>1 from jsonb_array_elements(tbl) p where p->>1 is not null) z;
      if not (left(card, 1) = any(ranks)) then raise exception 'rank not on table'; end if;
      select coalesce(array_length(cards, 1), 0) into dh from durak_hands where game_id = g and user_id = def;
      select count(*) into open_ from jsonb_array_elements(tbl) p where p->>1 is null;
      if jsonb_array_length(tbl) >= 6 or open_ + 1 > dh then raise exception 'table full'; end if;
    end if;
    update durak_hands set cards = array_remove(cards, card) where game_id = g and user_id = me_;
    tbl := tbl || jsonb_build_array(jsonb_build_array(card, null));
    update world_games set state = jsonb_set(jsonb_set(st, '{table}', tbl), '{log}', to_jsonb('Ход: ' || card)), turn = def, ver = ver + 1, updated_at = now() where id = g;

  elsif act = 'defend' then
    if me_ <> def or r.turn <> me_ then raise exception 'not your turn'; end if;
    if card is null or not (card = any(h)) then raise exception 'no such card'; end if;
    pair := tbl->i; if pair is null or pair->>1 is not null then raise exception 'bad pair'; end if;
    a_c := pair->>0;
    if not ((right(card, 1) = right(a_c, 1) and dk_rank(card) > dk_rank(a_c)) or (right(card, 1) = right(tr, 1) and right(a_c, 1) <> right(tr, 1))) then raise exception 'does not beat'; end if;
    update durak_hands set cards = array_remove(cards, card) where game_id = g and user_id = me_;
    tbl := jsonb_set(tbl, array[i::text], jsonb_build_array(a_c, card));
    select count(*) into open_ from jsonb_array_elements(tbl) p where p->>1 is null;
    update world_games set state = jsonb_set(jsonb_set(st, '{table}', tbl), '{log}', to_jsonb('Побил ' || a_c || ' картой ' || card)),
      turn = case when open_ = 0 then att else def end, ver = ver + 1, updated_at = now() where id = g;

  elsif act = 'take' then
    if me_ <> def or jsonb_array_length(tbl) = 0 then raise exception 'not your turn'; end if;
    update durak_hands set cards = cards || (select array_agg(x) from (select p->>0 x from jsonb_array_elements(tbl) p union all select p->>1 from jsonb_array_elements(tbl) p where p->>1 is not null) z) where game_id = g and user_id = me_;
    perform dk_refill(g, att, def);
    st := jsonb_set(st, '{log}', to_jsonb('Взял карты'::text));
    st := jsonb_set(st, '{table}', '[]'::jsonb);
    -- the attacker attacks again
    update world_games set state = st, turn = att, ver = ver + 1, updated_at = now() where id = g;

  elsif act = 'done' then
    if me_ <> att or r.turn <> me_ or jsonb_array_length(tbl) = 0 then raise exception 'not your turn'; end if;
    select count(*) into open_ from jsonb_array_elements(tbl) p where p->>1 is null;
    if open_ > 0 then raise exception 'not beaten yet'; end if;
    perform dk_refill(g, att, def);
    st := jsonb_set(st, '{out}', to_jsonb((st->>'out')::int + jsonb_array_length(tbl) * 2));
    st := jsonb_set(jsonb_set(st, '{table}', '[]'::jsonb), '{log}', to_jsonb('Бито'::text));
    st := jsonb_set(jsonb_set(st, '{att}', to_jsonb(def::text)), '{def}', to_jsonb(att::text));
    update world_games set state = st, turn = def, ver = ver + 1, updated_at = now() where id = g;
    att := (st->>'att')::uuid; def := (st->>'def')::uuid;
  else raise exception 'bad action';
  end if;

  -- sizes for both and the end of the game
  select coalesce(array_length(cards, 1), 0) into deckn from durak_deck where game_id = g;
  select coalesce(array_length(cards, 1), 0) into ha from durak_hands where game_id = g and user_id = r.a;
  select coalesce(array_length(cards, 1), 0) into hb from durak_hands where game_id = g and user_id = r.b;
  select state into st from world_games where id = g;
  st := jsonb_set(jsonb_set(st, '{deck}', to_jsonb(deckn)), '{hands}', jsonb_build_object(r.a::text, ha, r.b::text, hb));
  update world_games set state = st where id = g;
  if deckn = 0 and jsonb_array_length(st->'table') = 0 and (ha = 0 or hb = 0) then
    if ha = 0 and hb = 0 then
      update world_games set status = 'done', result = 'draw', turn = null, updated_at = now() where id = g;
      perform world_xp(r.a, 15); perform world_xp(r.b, 15);
    else
      w := case when ha = 0 then r.a else r.b end;
      update world_games set status = 'done', result = 'win', winner = w, turn = null, updated_at = now() where id = g;
      perform world_xp(w, 30); perform world_xp(case when w = r.a then r.b else r.a end, 10);
    end if;
  elsif deckn = 0 and (ha = 0 or hb = 0) and act = 'defend' then
    -- the defender beat everything with his last card: the round closes by itself
    null;
  end if;
end $$;
revoke all on function durak_play(uuid, text, text, int) from public, anon;
grant execute on function durak_play(uuid, text, text, int) to authenticated;

-- accepting a durak invite deals the cards
create or replace function game_answer(g uuid, ok boolean)
returns void language plpgsql security definer set search_path = public as $$
declare r world_games;
begin
  select * into r from world_games where id = g for update;
  if not found or r.b <> auth.uid() or r.status <> 'invite' then raise exception 'not your invite'; end if;
  update world_games set status = case when ok then 'active' else 'declined' end, turn = case when ok then r.a else null end, updated_at = now() where id = g;
  if ok and r.kind = 'durak' then perform durak_deal(g); end if;
end $$;

-- durak moves go only through durak_play
create or replace function game_move(g uuid, st jsonb, v int, fin text default null, win uuid default null)
returns void language plpgsql security definer set search_path = public as $$
declare r world_games; other uuid;
begin
  select * into r from world_games where id = g for update;
  if not found or auth.uid() not in (r.a, r.b) then raise exception 'not your game'; end if;
  if r.kind = 'durak' then raise exception 'use durak_play'; end if;
  if r.status <> 'active' then raise exception 'game over'; end if;
  if r.turn <> auth.uid() then raise exception 'not your turn'; end if;
  if r.ver <> v then raise exception 'stale'; end if;
  if st is null or pg_column_size(st) > 8000 then raise exception 'bad state'; end if;
  other := case when auth.uid() = r.a then r.b else r.a end;
  if fin is null then
    update world_games set state = st, ver = ver + 1, turn = other, updated_at = now() where id = g;
  else
    if fin not in ('win', 'draw') or (fin = 'win' and win not in (r.a, r.b)) then raise exception 'bad result'; end if;
    update world_games set state = st, ver = ver + 1, turn = null, status = 'done', result = fin, winner = case when fin = 'win' then win end, updated_at = now() where id = g;
    if fin = 'win' then perform world_xp(win, 30); perform world_xp(case when win = r.a then r.b else r.a end, 10);
    else perform world_xp(r.a, 15); perform world_xp(r.b, 15); end if;
  end if;
end $$;

create or replace function world_card(u uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('xp', dacha_xp(u),
    'open', exists (select 1 from world_members where user_id = u) or exists (select 1 from profiles where id = u and lower(tg_username) = 'tivishka'))
$$;
