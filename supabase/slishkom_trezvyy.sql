-- 07.11.2026: personal achievement for Толик (@tolikivanoff) for the game of 06.11
insert into public.achievements (id, title, description, icon) values
  ('slishkom-trezvyy', 'Слишком трезвый', 'Игра от 06.11.2026, в которой Анатолий не поверил ни одному другому комиссару, до конца топил Дена и лечил себя 🧊', 'ach/slishkom-trezvyy.svg')
on conflict (id) do update set title = excluded.title, description = excluded.description, icon = excluded.icon;
insert into public.user_achievements (user_id, achievement_id, awarded_at)
select id, 'slishkom-trezvyy', timestamptz '2026-11-06 17:30:00+00' from public.profiles where tg_username = 'tolikivanoff'
on conflict do nothing;
