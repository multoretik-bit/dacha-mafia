-- DACHA MAFIA: Saturday games, sign-ups and payments. Safe to re-run.
-- Times are local Phuket time (Asia/Bangkok).

create table if not exists public.events (
  id uuid primary key default gen_random_uuid(),
  day date not null unique,
  gather_time time not null default '19:30',
  start_time time not null default '20:00',
  price int not null default 100 check (price >= 0),
  note text check (char_length(note) <= 200),
  status text not null default 'open' check (status in ('open', 'cancelled')),
  created_at timestamptz not null default now()
);

create table if not exists public.signups (
  event_id uuid not null references public.events (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (event_id, user_id)
);

-- visible only to the player and the hosts
create table if not exists public.payments (
  event_id uuid not null,
  user_id uuid not null,
  method text not null check (method in ('qr', 'cash')),
  claimed_at timestamptz,
  confirmed_at timestamptz,
  confirmed_by uuid references public.profiles (id) on delete set null,
  primary key (event_id, user_id),
  foreign key (event_id, user_id) references public.signups (event_id, user_id) on delete cascade
);

create table if not exists public.pay_settings (
  id int primary key default 1 check (id = 1),
  qr_url text,
  qr_note text check (char_length(qr_note) <= 200),
  updated_at timestamptz not null default now()
);
insert into public.pay_settings (id) values (1) on conflict do nothing;

create or replace function public.bkk_today()
returns date language sql stable as $$ select (now() at time zone 'Asia/Bangkok')::date $$;

-- the next four Saturdays always exist
create or replace function public.ensure_events()
returns void language sql security definer set search_path = public as $$
  insert into events (day)
  select d::date from generate_series(public.bkk_today(), public.bkk_today() + 27, interval '1 day') d
  where extract(isodow from d) = 6
  on conflict (day) do nothing;
$$;
revoke all on function public.ensure_events() from public, anon;
grant execute on function public.ensure_events() to authenticated;

alter table public.events enable row level security;
alter table public.signups enable row level security;
alter table public.payments enable row level security;
alter table public.pay_settings enable row level security;

drop policy if exists "events readable" on public.events;
create policy "events readable" on public.events for select to authenticated using (true);
drop policy if exists "events by hosts" on public.events;
create policy "events by hosts" on public.events for all to authenticated using (public.can_host()) with check (public.can_host());

drop policy if exists "signups readable" on public.signups;
create policy "signups readable" on public.signups for select to authenticated using (true);
drop policy if exists "sign up self" on public.signups;
create policy "sign up self" on public.signups for insert to authenticated with check (
  user_id = auth.uid()
  and exists (select 1 from events e where e.id = event_id and e.status = 'open' and e.day >= public.bkk_today())
);
drop policy if exists "leave self or host removes" on public.signups;
create policy "leave self or host removes" on public.signups for delete to authenticated using (
  public.can_host() or (user_id = auth.uid() and exists (select 1 from events e where e.id = event_id and e.day >= public.bkk_today()))
);

drop policy if exists "payments self or host" on public.payments;
create policy "payments self or host" on public.payments for select to authenticated using (user_id = auth.uid() or public.can_host());

drop policy if exists "pay settings readable" on public.pay_settings;
create policy "pay settings readable" on public.pay_settings for select to authenticated using (true);
drop policy if exists "pay settings by hosts" on public.pay_settings;
create policy "pay settings by hosts" on public.pay_settings for update to authenticated using (public.can_host()) with check (public.can_host());

-- the player picks how they pay; claimed = "я перевёл". Only a host can confirm.
create or replace function public.set_payment(e uuid, m text, claimed boolean default false)
returns void language plpgsql security definer set search_path = public as $$
begin
  if m not in ('qr', 'cash') then raise exception 'bad method'; end if;
  if not exists (select 1 from signups where event_id = e and user_id = auth.uid()) then raise exception 'not signed up'; end if;
  insert into payments (event_id, user_id, method, claimed_at)
  values (e, auth.uid(), m, case when claimed then now() end)
  on conflict (event_id, user_id) do update
    set method = excluded.method,
        claimed_at = case when claimed then coalesce(payments.claimed_at, now()) when payments.method <> excluded.method then null else payments.claimed_at end,
        confirmed_at = case when payments.method <> excluded.method then null else payments.confirmed_at end;
end $$;
revoke all on function public.set_payment(uuid, text, boolean) from public, anon;
grant execute on function public.set_payment(uuid, text, boolean) to authenticated;

create or replace function public.confirm_payment(e uuid, u uuid, ok boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.can_host() then raise exception 'hosts only'; end if;
  insert into payments (event_id, user_id, method, confirmed_at, confirmed_by)
  values (e, u, 'cash', case when ok then now() end, case when ok then auth.uid() end)
  on conflict (event_id, user_id) do update
    set confirmed_at = case when ok then now() end, confirmed_by = case when ok then auth.uid() end;
end $$;
revoke all on function public.confirm_payment(uuid, uuid, boolean) from public, anon;
grant execute on function public.confirm_payment(uuid, uuid, boolean) to authenticated;

-- QR images for payment, uploaded by hosts
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('pay', 'pay', true, 3145728, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update set public = true;
drop policy if exists "hosts upload pay qr" on storage.objects;
create policy "hosts upload pay qr" on storage.objects for insert to authenticated with check (bucket_id = 'pay' and public.can_host());
drop policy if exists "hosts replace pay qr" on storage.objects;
create policy "hosts replace pay qr" on storage.objects for update to authenticated using (bucket_id = 'pay' and public.can_host());

do $$ begin
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'signups') then
    alter publication supabase_realtime add table public.signups;
  end if;
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'payments') then
    alter publication supabase_realtime add table public.payments;
  end if;
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'events') then
    alter publication supabase_realtime add table public.events;
  end if;
end $$;

-- first run: create the coming Saturdays; the next one starts earlier
select public.ensure_events();
update public.events set gather_time = '18:30', start_time = '19:00' where day = date '2026-10-24' and gather_time = '19:30';
