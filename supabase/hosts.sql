-- DACHA MAFIA: only listed Telegram accounts may host games. Safe to re-run.
-- Add a host:    insert into public.host_allowlist (tg_username) values ('username_without_at');
-- Remove a host: delete from public.host_allowlist where tg_username = 'username_without_at';

create table if not exists public.host_allowlist (
  tg_username text primary key check (tg_username = lower(tg_username)),
  added_at timestamptz not null default now()
);
alter table public.host_allowlist enable row level security; -- no policies: clients cannot read or change it

insert into public.host_allowlist (tg_username) values ('ruslan_shdl'), ('tivishka') on conflict do nothing;

-- tg_username is written only by the tg function from Telegram-signed data
create or replace function public.can_host(p uuid default auth.uid())
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from profiles pr join host_allowlist h on h.tg_username = lower(pr.tg_username)
    where pr.id = p
  );
$$;
revoke all on function public.can_host(uuid) from public, anon;
grant execute on function public.can_host(uuid) to authenticated;

drop policy if exists "games created by host" on public.games;
create policy "games created by host" on public.games
  for insert to authenticated with check (host_id = auth.uid() and public.can_host());

-- who can host, for the "ведущий" badge in lists
drop function if exists public.leaderboard();
create function public.leaderboard()
returns table (id uuid, nick text, color text, tg_username text, tg_name text, tg_photo text, games bigint, wins bigint, hosted bigint, is_host boolean)
language sql stable security definer set search_path = public as $$
  select pr.id, pr.nick, pr.color, pr.tg_username, pr.tg_name, pr.tg_photo,
    (select count(*) from seats s join games g on g.id = s.game_id where s.user_id = pr.id and g.status = 'finished'),
    (select count(*) from seats s join games g on g.id = s.game_id where s.user_id = pr.id and g.status = 'finished' and g.winner = s.team),
    (select count(*) from games g where g.host_id = pr.id and g.status = 'finished'),
    exists (select 1 from host_allowlist h where h.tg_username = lower(pr.tg_username))
  from profiles pr
  where pr.tg_id is not null
  order by 7 desc, 2;
$$;
revoke all on function public.leaderboard() from public, anon;
grant execute on function public.leaderboard() to authenticated;

-- avatars copied from Telegram by the tg function (public read, long cache)
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('avatars', 'avatars', true, 1048576, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update set public = true;

-- roster of a game for the notes screen: names, Telegram handle and avatar, never roles
drop function if exists public.game_roster(uuid);
create function public.game_roster(g uuid)
returns table (seat int, name text, user_id uuid, tg_username text, tg_photo text)
language sql stable security definer set search_path = public as $$
  select s.seat, coalesce(p.nick, s.guest_name), s.user_id, p.tg_username, p.tg_photo
  from seats s left join profiles p on p.id = s.user_id
  where s.game_id = g and (public.is_player(g) or public.is_host(g))
  order by s.seat;
$$;
revoke all on function public.game_roster(uuid) from public, anon;
grant execute on function public.game_roster(uuid) to authenticated;

-- deleting an account removes its seats (a seat must have a player or a guest name)
alter table public.seats drop constraint if exists seats_user_id_fkey;
alter table public.seats add constraint seats_user_id_fkey foreign key (user_id) references public.profiles (id) on delete cascade;

-- PREMIUM: granted in the app by @tivishka only; premium players see no ad banners
alter table public.profiles add column if not exists premium_until timestamptz;
create or replace function public.premium_ids()
returns setof uuid language sql stable security definer set search_path = public as $$
  select id from profiles where premium_until > now();
$$;
create or replace function public.can_grant_premium()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from profiles where id = auth.uid() and lower(tg_username) = 'tivishka');
$$;
create or replace function public.set_premium(u uuid, until timestamptz)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.can_grant_premium() then raise exception 'only @tivishka can grant premium'; end if;
  update profiles set premium_until = until where id = u;
end $$;
revoke all on function public.premium_ids() from public, anon;
revoke all on function public.can_grant_premium() from public, anon;
revoke all on function public.set_premium(uuid, timestamptz) from public, anon;
grant execute on function public.premium_ids() to authenticated;
grant execute on function public.can_grant_premium() to authenticated;
grant execute on function public.set_premium(uuid, timestamptz) to authenticated;
update public.profiles set premium_until = 'infinity' where lower(tg_username) = 'tigranich' and premium_until is null;

-- game flow: the host switches night/day, players see the phase and who is out (never roles)
alter table public.games add column if not exists phase text not null default 'setup';
alter table public.games drop constraint if exists games_phase_check;
alter table public.games add constraint games_phase_check check (phase in ('setup', 'night', 'day'));
alter table public.games add column if not exists round int not null default 0;
alter table public.seats add column if not exists alive boolean not null default true;
alter table public.seats add column if not exists died_round int;
alter table public.seats add column if not exists died_how text check (died_how in ('night', 'vote', 'host'));

drop function if exists public.game_roster(uuid);
create function public.game_roster(g uuid)
returns table (seat int, name text, user_id uuid, tg_username text, tg_photo text, alive boolean, died_round int, died_how text)
language sql stable security definer set search_path = public as $$
  select s.seat, coalesce(p.nick, s.guest_name), s.user_id, p.tg_username, p.tg_photo, s.alive, s.died_round, s.died_how
  from seats s left join profiles p on p.id = s.user_id
  where s.game_id = g and (public.is_player(g) or public.is_host(g))
  order by s.seat;
$$;
revoke all on function public.game_roster(uuid) from public, anon;
grant execute on function public.game_roster(uuid) to authenticated;

-- announcements: @tivishka writes a post in the app, the tg function sends it through the bot
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('announce', 'announce', true, 8388608, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update set public = true;
drop policy if exists "admin uploads announce images" on storage.objects;
create policy "admin uploads announce images" on storage.objects for insert to authenticated with check (bucket_id = 'announce' and public.can_grant_premium());

-- achievements shown in profiles
create table if not exists public.achievements (
  id text primary key,
  title text not null,
  description text not null,
  icon text not null,
  created_at timestamptz not null default now()
);
create table if not exists public.user_achievements (
  user_id uuid not null references public.profiles (id) on delete cascade,
  achievement_id text not null references public.achievements (id) on delete cascade,
  awarded_at timestamptz not null default now(),
  primary key (user_id, achievement_id)
);
alter table public.achievements enable row level security;
alter table public.user_achievements enable row level security;
drop policy if exists "achievements readable" on public.achievements;
create policy "achievements readable" on public.achievements for select to authenticated using (true);
drop policy if exists "user achievements readable" on public.user_achievements;
create policy "user achievements readable" on public.user_achievements for select to authenticated using (true);
drop policy if exists "admin awards achievements" on public.user_achievements;
create policy "admin awards achievements" on public.user_achievements for all to authenticated using (public.can_grant_premium()) with check (public.can_grant_premium());

insert into public.achievements (id, title, description, icon) values
  ('slishkom-tupo', 'Слишком Тупо', 'Игра от 28.10.2026, в которой Денис совершил самострел, но даже не знал правил священника и обосрался', 'ach/slishkom-tupo.webp')
on conflict (id) do update set title = excluded.title, description = excluded.description, icon = excluded.icon;
-- everyone who was at the 28.10 game: signed up for it or sat in a deal that day
insert into public.user_achievements (user_id, achievement_id, awarded_at)
select x.user_id, 'slishkom-tupo', timestamptz '2026-10-28 23:00+07' from (
  select s.user_id from public.signups s join public.events e on e.id = s.event_id where e.day = date '2026-10-28'
  union select s.user_id from public.seats s join public.games g on g.id = s.game_id
  where s.user_id is not null and (g.created_at at time zone 'Asia/Bangkok')::date = date '2026-10-28'
) x
on conflict do nothing;
