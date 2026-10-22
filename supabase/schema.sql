-- DACHA MAFIA: accounts, online games, role delivery, stats.
-- Run once in the Supabase SQL editor (or via the Management API). Safe to re-run.

create extension if not exists pgcrypto;

-- ---------- profiles ----------
create table if not exists public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  nick text not null check (char_length(nick) between 2 and 20),
  color text not null default 'blue',
  created_at timestamptz not null default now()
);
create unique index if not exists profiles_nick_lower on public.profiles (lower(nick));

create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, nick)
  values (new.id, coalesce(nullif(trim(new.raw_user_meta_data ->> 'nick'), ''), 'Дачник'));
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------- games ----------
create table if not exists public.games (
  id uuid primary key default gen_random_uuid(),
  host_id uuid not null references public.profiles (id) on delete cascade,
  status text not null default 'live' check (status in ('live', 'finished', 'cancelled')),
  winner text check (winner in ('city', 'mafia', 'solo')),
  mafia_sees_family boolean not null default true,
  created_at timestamptz not null default now(),
  finished_at timestamptz
);
create index if not exists games_host on public.games (host_id, created_at desc);

-- ---------- seats (one row per player in a game) ----------
create table if not exists public.seats (
  id bigint generated always as identity primary key,
  game_id uuid not null references public.games (id) on delete cascade,
  seat int not null,
  user_id uuid references public.profiles (id) on delete set null,
  guest_name text,
  role_id text not null,
  role_name text not null,
  role_code text not null,
  team text not null check (team in ('city', 'mafia', 'solo')),
  role_desc text,
  role_art text,
  seen_at timestamptz,
  created_at timestamptz not null default now(),
  check (user_id is not null or guest_name is not null)
);
create index if not exists seats_game on public.seats (game_id, seat);
create index if not exists seats_user on public.seats (user_id, created_at desc);

-- ---------- helpers (security definer so policies do not recurse) ----------
create or replace function public.is_host(g uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from games where id = g and host_id = auth.uid());
$$;

create or replace function public.is_player(g uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from seats where game_id = g and user_id = auth.uid());
$$;

-- true when the caller is mafia in game g and the host allowed the family to see each other
create or replace function public.sees_family(g uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from seats s join games gm on gm.id = s.game_id
    where s.game_id = g and s.user_id = auth.uid() and s.team = 'mafia'
      and gm.mafia_sees_family and gm.status = 'live'
  );
$$;

-- ---------- RLS ----------
alter table public.profiles enable row level security;
alter table public.games enable row level security;
alter table public.seats enable row level security;

drop policy if exists "profiles readable by members" on public.profiles;
create policy "profiles readable by members" on public.profiles
  for select to authenticated using (true);
drop policy if exists "profiles self update" on public.profiles;
create policy "profiles self update" on public.profiles
  for update to authenticated using (id = auth.uid()) with check (id = auth.uid());

drop policy if exists "games visible to host and players" on public.games;
create policy "games visible to host and players" on public.games
  for select to authenticated using (host_id = auth.uid() or public.is_player(id));
drop policy if exists "games created by host" on public.games;
create policy "games created by host" on public.games
  for insert to authenticated with check (host_id = auth.uid());
drop policy if exists "games updated by host" on public.games;
create policy "games updated by host" on public.games
  for update to authenticated using (host_id = auth.uid()) with check (host_id = auth.uid());
drop policy if exists "games deleted by host" on public.games;
create policy "games deleted by host" on public.games
  for delete to authenticated using (host_id = auth.uid());

-- a player sees only their own seat; the host sees every seat; mafia sees mafia when allowed
drop policy if exists "seats visibility" on public.seats;
create policy "seats visibility" on public.seats
  for select to authenticated using (
    user_id = auth.uid()
    or public.is_host(game_id)
    or (team = 'mafia' and public.sees_family(game_id))
  );
drop policy if exists "seats written by host" on public.seats;
create policy "seats written by host" on public.seats
  for insert to authenticated with check (public.is_host(game_id));
drop policy if exists "seats deleted by host" on public.seats;
create policy "seats deleted by host" on public.seats
  for delete to authenticated using (public.is_host(game_id));

-- players mark their own card as seen through this function only
create or replace function public.mark_seen(seat_id bigint)
returns void language sql security definer set search_path = public as $$
  update seats set seen_at = coalesce(seen_at, now()) where id = seat_id and user_id = auth.uid();
$$;

-- ---------- stats (finished games only, so a live game never leaks roles) ----------
create or replace function public.player_stats(p uuid)
returns table (role_id text, role_name text, team text, games bigint, wins bigint)
language sql stable security definer set search_path = public as $$
  select s.role_id, max(s.role_name), max(s.team), count(*), count(*) filter (where g.winner = s.team)
  from seats s join games g on g.id = s.game_id
  where s.user_id = p and g.status = 'finished'
  group by s.role_id
  order by count(*) desc;
$$;

create or replace function public.leaderboard()
returns table (id uuid, nick text, color text, games bigint, wins bigint, hosted bigint)
language sql stable security definer set search_path = public as $$
  select pr.id, pr.nick, pr.color,
    (select count(*) from seats s join games g on g.id = s.game_id where s.user_id = pr.id and g.status = 'finished'),
    (select count(*) from seats s join games g on g.id = s.game_id where s.user_id = pr.id and g.status = 'finished' and g.winner = s.team),
    (select count(*) from games g where g.host_id = pr.id and g.status = 'finished')
  from profiles pr
  order by 4 desc, 2;
$$;

revoke all on function public.player_stats(uuid) from public, anon;
revoke all on function public.leaderboard() from public, anon;
revoke all on function public.mark_seen(bigint) from public, anon;
grant execute on function public.player_stats(uuid) to authenticated;
grant execute on function public.leaderboard() to authenticated;
grant execute on function public.mark_seen(bigint) to authenticated;

-- ---------- realtime ----------
do $$ begin
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'seats') then
    alter publication supabase_realtime add table public.seats;
  end if;
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'games') then
    alter publication supabase_realtime add table public.games;
  end if;
end $$;

-- signup form checks a nickname before creating the account
create or replace function public.nick_taken(n text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from profiles where lower(nick) = lower(trim(n)));
$$;
grant execute on function public.nick_taken(text) to anon, authenticated;

-- host marks a guest's card as seen
drop policy if exists "seats updated by host" on public.seats;
create policy "seats updated by host" on public.seats
  for update to authenticated using (public.is_host(game_id)) with check (public.is_host(game_id));

-- names by seat (no roles) for the player's notebook
create or replace function public.game_roster(g uuid)
returns table (seat int, name text, user_id uuid)
language sql stable security definer set search_path = public as $$
  select s.seat, coalesce(p.nick, s.guest_name), s.user_id
  from seats s left join profiles p on p.id = s.user_id
  where s.game_id = g and (public.is_player(g) or public.is_host(g))
  order by s.seat;
$$;
revoke all on function public.game_roster(uuid) from public, anon;
grant execute on function public.game_roster(uuid) to authenticated;
