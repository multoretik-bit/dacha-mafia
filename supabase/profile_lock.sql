-- DACHA 05.11: @tivishka can lock a profile — everybody sees it grey and closed
alter table profiles add column if not exists locked boolean not null default false;
create or replace function set_profile_lock(u uuid, on_ boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not can_grant_premium() then raise exception 'only tivishka'; end if;
  update profiles set locked = on_ where id = u;
end $$;
revoke all on function set_profile_lock(uuid, boolean) from public, anon;
grant execute on function set_profile_lock(uuid, boolean) to authenticated;
update profiles set locked = true where lower(tg_username) = 'tigranich';
