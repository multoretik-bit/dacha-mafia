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
