-- DACHA WORLD 06.11: the chosen dacha is remembered for good; it can be changed only in the profile settings.
-- Four dachas: Phuket (open), Bali, Moscow, Saint Petersburg (closed for now).
alter table profiles add column if not exists world_dacha text check (world_dacha in ('phuket', 'bali', 'moscow', 'spb'));

create or replace function set_world_dacha(d text) returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'login'; end if;
  if d not in ('phuket', 'bali', 'moscow', 'spb') then raise exception 'bad dacha'; end if;
  if d <> 'phuket' then raise exception 'locked'; end if;
  update profiles set world_dacha = d where id = auth.uid();
end $$;
revoke all on function set_world_dacha(text) from public, anon;
grant execute on function set_world_dacha(text) to authenticated;

create or replace function my_world_dacha() returns text language sql stable security definer set search_path = public as $$
  select world_dacha from profiles where id = auth.uid()
$$;
revoke all on function my_world_dacha() from public, anon;
grant execute on function my_world_dacha() to authenticated;
