-- 07.11.2026: personal achievement for Матвей (@takoy_vot_ya)
insert into public.achievements (id, title, description, icon) values
  ('slishkom-mirnyy', 'Слишком мирный', '13 игр подряд играл на мирных ролях 🕊', 'ach/slishkom-mirnyy.svg')
on conflict (id) do update set title = excluded.title, description = excluded.description, icon = excluded.icon;
insert into public.user_achievements (user_id, achievement_id)
select id, 'slishkom-mirnyy' from public.profiles where tg_username = 'takoy_vot_ya'
on conflict do nothing;
