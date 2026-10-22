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
