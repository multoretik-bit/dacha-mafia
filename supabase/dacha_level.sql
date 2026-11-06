-- DACHA 06.11: one level for everything a dachnik does.
-- XP: mafia game played 20 (won +10, hosted 30) · volleyball/football played 20 (+5 per win) · community event 15
--     PREMIUM month 100 · a top-up 10 · a tomato purchase 10 · care & board games in DACHA WORLD (world_chars.xp)
--     (messages in the app — later)
-- Level L needs 50·L·(L−1) XP: 2 → 100, 3 → 300, 4 → 600, 5 → 1000, 10 → 4500.
create or replace function dacha_xp(u uuid) returns int language sql stable security definer set search_path = public as $$
  select (
      20 * (select count(distinct s.game_id) from seats s join games g on g.id = s.game_id where s.user_id = u and g.status = 'finished')
    + 10 * (select count(*) from seats s join games g on g.id = s.game_id where s.user_id = u and g.status = 'finished' and g.winner is not null and g.winner = s.team)
    + 30 * (select count(*) from games where host_id = u and status = 'finished')
    + 20 * (select count(*) from sport_results where user_id = u)
    +  5 * (select coalesce(sum(wins), 0) from sport_results where user_id = u)
    + 15 * (select count(*) from csignups c join cevents e on e.id = c.event_id where c.user_id = u and c.day <= (now() at time zone 'Asia/Bangkok')::date)
    + 100 * (select count(*) from wallet_tx where user_id = u and purpose = 'premium' and status = 'confirmed')
    + 10 * (select count(*) from wallet_tx where user_id = u and purpose = 'topup' and status = 'confirmed' and method in ('qr', 'cash') and event_id is null)
    + 10 * (select count(*) from wallet_tx where user_id = u and purpose = 'topup' and status = 'confirmed' and amount < 0 and note like '🍅%')
    + coalesce((select xp from world_chars where user_id = u), 0)
  )::int
$$;
revoke all on function dacha_xp(uuid) from public, anon;
grant execute on function dacha_xp(uuid) to authenticated;

-- the board of levels for the world rating
create or replace function dacha_levels() returns table (user_id uuid, xp int) language sql stable security definer set search_path = public as $$
  select p.id, dacha_xp(p.id) from profiles p where p.tg_id is not null order by 2 desc limit 60
$$;
revoke all on function dacha_levels() from public, anon;
grant execute on function dacha_levels() to authenticated;

create or replace function world_card(u uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'xp', dacha_xp(u),
    'open', exists (select 1 from world_members where user_id = u) or exists (select 1 from profiles where id = u and lower(tg_username) = 'tivishka'),
    'chess_w', (select count(*) from world_games where kind = 'chess' and status = 'done' and winner = u),
    'chess_n', (select count(*) from world_games where kind = 'chess' and status = 'done' and u in (a, b)),
    'checkers_w', (select count(*) from world_games where kind = 'checkers' and status = 'done' and winner = u),
    'checkers_n', (select count(*) from world_games where kind = 'checkers' and status = 'done' and u in (a, b)))
$$;

-- board games: anyone can be invited (the invite link opens the game even if DACHA WORLD is still closed for him)
create or replace function game_invite(k text, opp uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare id_ uuid;
begin
  if not has_world() then raise exception 'no access'; end if;
  if opp is null or opp = auth.uid() or not exists (select 1 from profiles where id = opp and tg_id is not null) then raise exception 'bad opponent'; end if;
  if (select count(*) from world_games where a = auth.uid() and status = 'invite' and created_at > now() - interval '1 hour') >= 10 then raise exception 'too many'; end if;
  insert into world_games (kind, a, b) values (k, auth.uid(), opp) returning id into id_;
  return id_;
end $$;
