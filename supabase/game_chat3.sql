-- 08.11.2026: чат стола целиком с сервера — по одному разу каждое сообщение, новые первыми; видят все, кто за столом.
create or replace function game_chat(g uuid) returns setof dm_messages language sql stable security definer set search_path = public as $$
  select * from (
    select distinct on (coalesce(m.grp, m.id)) m.* from dm_messages m
    where m.game_id = g and exists (select 1 from world_games w where w.id = g and (auth.uid() = w.a or auth.uid() = w.b or auth.uid() = any(w.players)))
    order by coalesce(m.grp, m.id), m.created_at
  ) x order by x.created_at desc limit 300
$$;
revoke all on function game_chat(uuid) from public, anon;
grant execute on function game_chat(uuid) to authenticated;
