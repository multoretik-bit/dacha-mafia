-- 02.11.2026: most wins in October 2026 (Bangkok time) — @iry_eng and @tigranich, 8 wins each
insert into public.achievements (id, title, description, icon) values
  ('top-october-2026', 'Топ октября', 'Больше всех побед на даче в октябре 2026 — 8 побед. Лучший игрок месяца 🏆', 'ach/top-october-2026.svg')
on conflict (id) do update set title = excluded.title, description = excluded.description, icon = excluded.icon;

with w as (
  select s.user_id, count(*) filter (where s.team = g.winner) wins
  from public.seats s join public.games g on g.id = s.game_id
  where g.status = 'finished' and s.user_id is not null
    and (g.created_at at time zone 'Asia/Bangkok') >= '2026-10-01' and (g.created_at at time zone 'Asia/Bangkok') < '2026-11-01'
  group by s.user_id
)
insert into public.user_achievements (user_id, achievement_id)
select user_id, 'top-october-2026' from w where wins = (select max(wins) from w)
on conflict do nothing;
