-- DACHA: locations for every event + weekly sport games (series)

create table if not exists places (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 1 and 80),
  maps_url text check (maps_url is null or maps_url ~* '^https?://'),
  lat double precision,
  lng double precision,
  created_by uuid references profiles(id) on delete set null,
  created_at timestamptz not null default now()
);

-- anyone who hosts something (mafia, volleyball, football) or @tivishka
create or replace function is_any_host(p uuid default auth.uid())
returns boolean language sql stable security definer set search_path = public as $$
  select can_host(p) or exists (select 1 from sport_hosts where user_id = p)
      or exists (select 1 from profiles where id = p and lower(tg_username) = 'tivishka');
$$;
grant execute on function is_any_host(uuid) to anon, authenticated;

alter table places enable row level security;
drop policy if exists "places readable" on places;
create policy "places readable" on places for select using (true);
drop policy if exists "places by hosts" on places;
create policy "places by hosts" on places for insert with check (is_any_host());
drop policy if exists "places edit by hosts" on places;
create policy "places edit by hosts" on places for update using (is_any_host()) with check (is_any_host());

alter table events add column if not exists place_id uuid references places(id) on delete set null;
alter table sport_events add column if not exists place_id uuid references places(id) on delete set null;

-- weekly games: every <dow> at <start_time>
create table if not exists sport_series (
  id uuid primary key default gen_random_uuid(),
  sport text not null check (sport in ('volley', 'foot')),
  dow int not null check (dow between 0 and 6),          -- 0 = Sunday … 4 = Thursday
  start_time time not null default '19:00',
  price int not null default 0 check (price >= 0),
  place_id uuid references places(id) on delete set null,
  note text,
  active boolean not null default true,
  created_by uuid references profiles(id) on delete set null,
  created_at timestamptz not null default now()
);
alter table sport_series enable row level security;
drop policy if exists "series readable" on sport_series;
create policy "series readable" on sport_series for select using (true);
drop policy if exists "series by hosts" on sport_series;
create policy "series by hosts" on sport_series for all using (can_sport_host(sport)) with check (can_sport_host(sport));

alter table sport_events add column if not exists series_id uuid references sport_series(id) on delete set null;
create unique index if not exists sport_events_series_day on sport_events (series_id, day);

-- keeps the next 4 weeks of every active series in the calendar; a removed date is not brought back
create or replace function ensure_sport_events()
returns void language sql security definer set search_path = public as $$
  insert into sport_events (sport, day, start_time, price, place_id, note, series_id, created_by)
  select s.sport, d::date, s.start_time, s.price, s.place_id, s.note, s.id, s.created_by
  from sport_series s, generate_series(bkk_today(), bkk_today() + 27, interval '1 day') d
  where s.active and extract(dow from d) = s.dow
  on conflict (series_id, day) do nothing;
$$;
grant execute on function ensure_sport_events() to anon, authenticated;

-- a changed series updates its future dates that nobody edited by hand is too fragile; the client
-- updates future open dates of the series explicitly when the host saves the series.

alter publication supabase_realtime add table sport_series;

-- 05.11 data: VBL Beach Volleyball Stadium (volleyball every Thursday 19:00, 250 ฿),
-- Ali BBQ Kathu for mafia (default place of new mafia dates: alter table events alter column place_id set default '<id>')
