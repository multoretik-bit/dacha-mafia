-- 01.11.2026: games belong to the app, not to one host: any allowed host can open, run and finish any game.
-- host_id stays the creator (stats, «ведущий» on the card).
create or replace function public.is_host(g uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from games where id = g and (host_id = auth.uid() or public.can_host()));
$$;

drop policy if exists "games visible to host and players" on public.games;
create policy "games visible to host and players" on public.games for select
  using (host_id = auth.uid() or public.is_player(id) or public.can_host());

drop policy if exists "games updated by host" on public.games;
create policy "games updated by host" on public.games for update
  using (host_id = auth.uid() or public.can_host())
  with check (host_id = auth.uid() or public.can_host());

drop policy if exists "games deleted by host" on public.games;
create policy "games deleted by host" on public.games for delete
  using (host_id = auth.uid() or public.can_host());

-- anon reads of games must not error (it returns false for anon)
grant execute on function public.can_host(uuid) to anon;
