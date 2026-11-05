-- 05.11.2026: rating for one month. A game belongs to its game night: Bangkok time minus 6 h
-- (a game started after midnight still counts to the evening it was played on).
create or replace function public.game_month(t timestamptz) returns date
language sql immutable as $$ select date_trunc('month', (t at time zone 'Asia/Bangkok') - interval '6 hours')::date $$;

create or replace function public.month_board(m date)
returns table (id uuid, nick text, color text, tg_username text, tg_name text, tg_photo text, games bigint, wins bigint, hosted bigint, is_host boolean)
language sql stable security definer set search_path = public as $$
  with g as (select * from games where status = 'finished' and public.game_month(created_at) = date_trunc('month', m)::date)
  select pr.id, pr.nick, pr.color, pr.tg_username, pr.tg_name, pr.tg_photo,
    (select count(*) from seats s join g on g.id = s.game_id where s.user_id = pr.id),
    (select count(*) from seats s join g on g.id = s.game_id where s.user_id = pr.id and g.winner = s.team),
    (select count(*) from g where g.host_id = pr.id),
    exists (select 1 from host_allowlist h where h.tg_username = lower(pr.tg_username))
  from profiles pr
  where pr.tg_id is not null
  order by 8 desc, 7 desc, 2;
$$;
revoke execute on function public.month_board(date) from public, anon;
grant execute on function public.month_board(date) to authenticated;
