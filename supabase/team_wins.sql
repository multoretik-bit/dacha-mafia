-- 04.11.2026: wins per team over all finished games (for the hot bar in «Дачники»); everyone may read
create or replace function public.team_wins() returns table (winner text, n bigint)
language sql stable security definer set search_path = public as $$
  select winner, count(*) from games where status = 'finished' and winner is not null group by winner
$$;
revoke execute on function public.team_wins() from public;
grant execute on function public.team_wins() to anon, authenticated;
