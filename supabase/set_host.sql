-- 01.11.2026: only @tivishka makes a dachnik a host or takes it away (host_allowlist is by tg_username)
create or replace function public.set_host(u uuid, on_ boolean) returns void
language plpgsql security definer set search_path = public as $$
declare n text;
begin
  if not public.can_grant_premium() then raise exception 'only @tivishka can appoint hosts'; end if;
  select lower(tg_username) into n from profiles where id = u;
  if n is null or n = '' then raise exception 'у дачника нет ника в Telegram'; end if;
  if not on_ and u = auth.uid() then raise exception 'себя из ведущих убрать нельзя'; end if;
  if on_ then insert into host_allowlist (tg_username) values (n) on conflict do nothing;
  else delete from host_allowlist where tg_username = n;
  end if;
end $$;
revoke execute on function public.set_host(uuid, boolean) from public, anon;
grant execute on function public.set_host(uuid, boolean) to authenticated;
