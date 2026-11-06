-- DACHA 06.11: messages exist only inside online games (chess, checkers, durak…) between the two players.
alter table dm_messages add column if not exists game_id uuid references world_games(id) on delete cascade;
create index if not exists dm_game on dm_messages (game_id, created_at);
drop function if exists dm_send(uuid, text);
create or replace function dm_send(to_ uuid, body_ text, g uuid) returns uuid language plpgsql security definer set search_path = public as $$
declare id_ uuid; t text := left(trim(body_), 1000);
begin
  if t = '' then raise exception 'empty'; end if;
  if not exists (select 1 from world_games where id = g and ((a = auth.uid() and b = to_) or (b = auth.uid() and a = to_))) then raise exception 'not your game'; end if;
  if (select count(*) from dm_messages where from_id = auth.uid() and created_at > now() - interval '1 minute') >= 30 then raise exception 'too fast'; end if;
  insert into dm_messages (from_id, to_id, body, game_id) values (auth.uid(), to_, t, g) returning id into id_;
  return id_;
end $$;
create or replace function dm_read_game(g uuid) returns void language sql security definer set search_path = public as $$
  update dm_messages set read_at = now() where to_id = auth.uid() and game_id = g and read_at is null;
$$;
revoke all on function dm_send(uuid, text, uuid) from public, anon;
revoke all on function dm_read_game(uuid) from public, anon;
grant execute on function dm_send(uuid, text, uuid) to authenticated;
grant execute on function dm_read_game(uuid) to authenticated;
