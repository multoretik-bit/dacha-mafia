-- 07.11.2026: «Дурак» на полной колоде — 52 карты (2…A), честная перетасовка (gen_random_uuid), 6 на руки, остальное в колоду.
create or replace function dk_rank(c text) returns int language sql immutable as $$ select position(left(c, 1) in '23456789TJQKA') $$;

create or replace function durak_deal(g uuid) returns void language plpgsql security definer set search_path = public as $$
declare r world_games; deck text[]; ha text[]; hb text[]; tr text; att uuid; la int; lb int; n int;
begin
  select * into r from world_games where id = g;
  -- every deal is a fresh, cryptographically random order of all 52 cards
  select array_agg(c order by gen_random_uuid()) into deck
    from (select rk || s as c from unnest(array['2','3','4','5','6','7','8','9','T','J','Q','K','A']) rk, unnest(array['S','H','D','C']) s) x;
  ha := deck[1:6]; hb := deck[7:12]; deck := deck[13:52]; n := array_length(deck, 1);
  tr := deck[n];   -- the bottom card shows the trump
  select min(dk_rank(c)) into la from unnest(ha) c where right(c, 1) = right(tr, 1);
  select min(dk_rank(c)) into lb from unnest(hb) c where right(c, 1) = right(tr, 1);
  att := case when lb is not null and (la is null or lb < la) then r.b else r.a end;
  insert into durak_deck values (g, deck) on conflict (game_id) do update set cards = excluded.cards;
  insert into durak_hands values (g, r.a, ha), (g, r.b, hb) on conflict (game_id, user_id) do update set cards = excluded.cards;
  update world_games set turn = att, ver = ver + 1, updated_at = now(), state = jsonb_build_object(
    'trump', tr, 'deck', n, 'table', '[]'::jsonb, 'att', att, 'def', case when att = r.a then r.b else r.a end,
    'hands', jsonb_build_object(r.a::text, 6, r.b::text, 6), 'out', 0, 'log', 'Раздача: козырь ' || tr) where id = g;
end $$;
revoke all on function durak_deal(uuid) from public, anon, authenticated;
