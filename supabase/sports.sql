-- DACHA: volleyball and football — dates, sign-ups, results and ratings.
-- Mafia keeps its own tables (events/signups/games/seats); sports live here.

create table if not exists sport_events (
  id uuid primary key default gen_random_uuid(),
  sport text not null check (sport in ('volley', 'foot')),
  day date not null,
  start_time time not null default '18:00',
  place text,
  note text,
  price int not null default 0 check (price >= 0),
  status text not null default 'open' check (status in ('open', 'done', 'removed')),
  created_by uuid references profiles(id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists sport_events_day on sport_events (day);

create table if not exists sport_signups (
  event_id uuid not null references sport_events(id) on delete cascade,
  user_id uuid not null references profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (event_id, user_id)
);

create table if not exists sport_results (
  event_id uuid not null references sport_events(id) on delete cascade,
  user_id uuid not null references profiles(id) on delete cascade,
  result text not null check (result in ('win', 'loss', 'draw')),
  set_by uuid references profiles(id) on delete set null,
  set_at timestamptz not null default now(),
  primary key (event_id, user_id)
);

-- sport hosts: appointed only by @tivishka
create table if not exists sport_hosts (
  sport text not null check (sport in ('volley', 'foot')),
  user_id uuid not null references profiles(id) on delete cascade,
  added_at timestamptz not null default now(),
  primary key (sport, user_id)
);

create or replace function can_sport_host(s text, p uuid default auth.uid())
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from profiles where id = p and lower(tg_username) = 'tivishka')
      or exists (select 1 from sport_hosts where sport = s and user_id = p);
$$;
grant execute on function can_sport_host(text, uuid) to anon, authenticated;

alter table sport_events enable row level security;
alter table sport_signups enable row level security;
alter table sport_results enable row level security;
alter table sport_hosts enable row level security;

drop policy if exists "sport events readable" on sport_events;
create policy "sport events readable" on sport_events for select using (true);
drop policy if exists "sport events by hosts" on sport_events;
create policy "sport events by hosts" on sport_events for all using (can_sport_host(sport)) with check (can_sport_host(sport));

drop policy if exists "sport signups readable" on sport_signups;
create policy "sport signups readable" on sport_signups for select using (true);
drop policy if exists "sport sign up self" on sport_signups;
create policy "sport sign up self" on sport_signups for insert with check (
  user_id = auth.uid() and exists (select 1 from sport_events e where e.id = event_id and e.status = 'open' and e.day >= bkk_today()));
drop policy if exists "sport leave self or host" on sport_signups;
create policy "sport leave self or host" on sport_signups for delete using (
  (user_id = auth.uid() and exists (select 1 from sport_events e where e.id = event_id and e.day >= bkk_today()))
  or exists (select 1 from sport_events e where e.id = event_id and can_sport_host(e.sport)));

drop policy if exists "sport results readable" on sport_results;
create policy "sport results readable" on sport_results for select using (true);
drop policy if exists "sport results by hosts" on sport_results;
create policy "sport results by hosts" on sport_results for all
  using (exists (select 1 from sport_events e where e.id = event_id and can_sport_host(e.sport)))
  with check (exists (select 1 from sport_events e where e.id = event_id and can_sport_host(e.sport)));

drop policy if exists "sport hosts readable" on sport_hosts;
create policy "sport hosts readable" on sport_hosts for select using (true);

-- appoint / remove a sport host — only @tivishka
create or replace function set_sport_host(u uuid, s text, on_ boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not can_grant_premium() then raise exception 'only tivishka'; end if;
  if s not in ('volley', 'foot') then raise exception 'bad sport'; end if;
  if on_ then insert into sport_hosts (sport, user_id) values (s, u) on conflict do nothing;
  else delete from sport_hosts where sport = s and user_id = u; end if;
end $$;
revoke all on function set_sport_host(uuid, text, boolean) from public, anon;
grant execute on function set_sport_host(uuid, text, boolean) to authenticated;

-- save the results of one game at once: rows = [{u, r}] ; marks the date as played
create or replace function save_sport_results(e uuid, rows jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare sp text;
begin
  select sport into sp from sport_events where id = e;
  if sp is null then raise exception 'no event'; end if;
  if not can_sport_host(sp) then raise exception 'only sport host'; end if;
  delete from sport_results where event_id = e;
  insert into sport_results (event_id, user_id, result, set_by)
    select e, (x->>'u')::uuid, x->>'r', auth.uid() from jsonb_array_elements(rows) x
    where x->>'r' in ('win', 'loss', 'draw');
  update sport_events set status = case when jsonb_array_length(rows) > 0 then 'done' else 'open' end where id = e and status <> 'removed';
end $$;
revoke all on function save_sport_results(uuid, jsonb) from public, anon;
grant execute on function save_sport_results(uuid, jsonb) to authenticated;

-- rating: all time (m is null) or one calendar month (m = first day)
create or replace function sport_board(s text, m date default null)
returns table(id uuid, nick text, color text, tg_username text, tg_name text, tg_photo text, games bigint, wins bigint, losses bigint, draws bigint)
language sql stable security definer set search_path = public as $$
  select pr.id, pr.nick, pr.color, pr.tg_username, pr.tg_name, pr.tg_photo,
    count(*), count(*) filter (where r.result = 'win'), count(*) filter (where r.result = 'loss'), count(*) filter (where r.result = 'draw')
  from sport_results r
  join sport_events e on e.id = r.event_id and e.status <> 'removed' and e.sport = s
  join profiles pr on pr.id = r.user_id
  where m is null or date_trunc('month', e.day)::date = m
  group by pr.id
  order by 8 desc, 7 desc, 2;
$$;
grant execute on function sport_board(text, date) to anon, authenticated;

-- profile: everything about one person in every game
create or replace function sport_stats(p uuid)
returns table(sport text, games bigint, wins bigint, losses bigint, draws bigint, place bigint)
language sql stable security definer set search_path = public as $$
  with b as (
    select e.sport, r.user_id, count(*) g, count(*) filter (where r.result = 'win') w,
      count(*) filter (where r.result = 'loss') l, count(*) filter (where r.result = 'draw') d
    from sport_results r join sport_events e on e.id = r.event_id and e.status <> 'removed'
    group by 1, 2
  ), ranked as (select *, rank() over (partition by sport order by w desc, g desc) rk from b)
  select sport, g, w, l, d, rk from ranked where user_id = p;
$$;
grant execute on function sport_stats(uuid) to anon, authenticated;

-- "about me" line on the profile
alter table profiles add column if not exists bio text check (char_length(bio) <= 160);
grant update (bio) on profiles to authenticated;   -- only nick and bio are editable by the user (RLS: own row)

alter publication supabase_realtime add table sport_events, sport_signups, sport_results;
