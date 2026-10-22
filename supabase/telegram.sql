-- DACHA MAFIA: sign-in through the Telegram mini app (run after schema.sql). Safe to re-run.

alter table public.profiles add column if not exists tg_id bigint unique;
alter table public.profiles add column if not exists tg_username text;
alter table public.profiles add column if not exists tg_name text;
alter table public.profiles add column if not exists tg_photo text;

-- identity is the Telegram account now, so nicknames may repeat
drop index if exists public.profiles_nick_lower;
alter table public.profiles drop constraint if exists profiles_nick_check;
alter table public.profiles add constraint profiles_nick_check check (char_length(trim(nick)) between 1 and 24);

-- players may change only their nickname; Telegram fields are written by the tg function
revoke update on public.profiles from authenticated;
grant update (nick) on public.profiles to authenticated;

alter table public.games add column if not exists notified_at timestamptz;

create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
declare m jsonb := new.raw_user_meta_data;
begin
  insert into public.profiles (id, nick, tg_id, tg_username, tg_name, tg_photo)
  values (
    new.id,
    left(coalesce(nullif(trim(m ->> 'nick'), ''), 'Дачник'), 24),
    nullif(m ->> 'tg_id', '')::bigint,
    nullif(m ->> 'tg_username', ''),
    nullif(m ->> 'tg_name', ''),
    nullif(m ->> 'tg_photo', '')
  );
  return new;
end $$;

drop function if exists public.leaderboard();
create function public.leaderboard()
returns table (id uuid, nick text, color text, tg_username text, tg_name text, tg_photo text, games bigint, wins bigint, hosted bigint)
language sql stable security definer set search_path = public as $$
  select pr.id, pr.nick, pr.color, pr.tg_username, pr.tg_name, pr.tg_photo,
    (select count(*) from seats s join games g on g.id = s.game_id where s.user_id = pr.id and g.status = 'finished'),
    (select count(*) from seats s join games g on g.id = s.game_id where s.user_id = pr.id and g.status = 'finished' and g.winner = s.team),
    (select count(*) from games g where g.host_id = pr.id and g.status = 'finished')
  from profiles pr
  where pr.tg_id is not null
  order by 7 desc, 2;
$$;
revoke all on function public.leaderboard() from public, anon;
grant execute on function public.leaderboard() to authenticated;

drop function if exists public.nick_taken(text);
