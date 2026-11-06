-- DACHA 06.11: 5 minutes per move. Whoever's turn it is and doesn't move loses; either player (or anyone of the two) can call it.
create or replace function game_timeout(g uuid) returns boolean language plpgsql security definer set search_path = public as $$
declare r world_games; w uuid;
begin
  select * into r from world_games where id = g for update;
  if not found or auth.uid() not in (r.a, r.b) or r.status <> 'active' or r.turn is null then return false; end if;
  if r.updated_at > now() - interval '5 minutes' then return false; end if;
  w := case when r.turn = r.a then r.b else r.a end;
  update world_games set status = 'done', result = 'timeout', winner = w, turn = null, ver = ver + 1, updated_at = now() where id = g;
  perform world_xp(w, 30); perform world_xp(case when w = r.a then r.b else r.a end, 5);
  return true;
end $$;
revoke all on function game_timeout(uuid) from public, anon;
grant execute on function game_timeout(uuid) to authenticated;
