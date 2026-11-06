-- DACHA 06.11: DACHA WORLD is open for every dachnik (except locked accounts)
create or replace function has_world() returns boolean language sql stable security definer set search_path = public as $$
  select auth.uid() is not null and exists (select 1 from profiles where id = auth.uid() and tg_id is not null and not coalesce(locked, false))
$$;
create or replace function world_people() returns setof uuid language sql stable security definer set search_path = public as $$
  select id from profiles where tg_id is not null and not coalesce(locked, false) and has_world()
$$;
