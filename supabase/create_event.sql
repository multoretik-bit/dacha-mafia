-- 31.10: @tivishka creates and removes game dates from the app
create or replace function public.create_event(d date, g time, s time, p int, n text)
returns uuid language plpgsql security definer set search_path = public as $$
declare r uuid;
begin
  if not public.can_grant_premium() then raise exception 'Даты создаёт только @tivishka'; end if;
  if d < public.bkk_today() then raise exception 'Эта дата уже прошла'; end if;
  insert into events (day, gather_time, start_time, price, note, status)
  values (d, g, s, greatest(0, coalesce(p, 100)), nullif(trim(n), ''), 'open')
  on conflict (day) do update set gather_time = excluded.gather_time, start_time = excluded.start_time,
    price = excluded.price, note = excluded.note, status = 'open'
  returning id into r;
  return r;
end $$;
revoke all on function public.create_event(date, time, time, int, text) from public, anon;
grant execute on function public.create_event(date, time, time, int, text) to authenticated;

create or replace function public.remove_event(e uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.can_grant_premium() then raise exception 'Даты убирает только @tivishka'; end if;
  update events set status = 'removed' where id = e;
end $$;
revoke all on function public.remove_event(uuid) from public, anon;
grant execute on function public.remove_event(uuid) to authenticated;

insert into events (day, gather_time, start_time, price) values ('2026-12-31', '18:30', '19:00', 100)
on conflict (day) do update set status = 'open';
