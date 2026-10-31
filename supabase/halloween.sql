-- 31.10.2026: everyone dealt a card today (and the hosts) gets «Хэллоуин на даче»
insert into public.achievements (id, title, description, icon) values
  ('halloween-2026', 'Хэллоуин на даче', 'Играл в мафию на даче в Хэллоуин, 31 октября 2026. Тыквы, летучие мыши и мафия в темноте 🎃', 'ach/halloween-2026.svg')
on conflict (id) do update set title = excluded.title, description = excluded.description, icon = excluded.icon;

-- new.user_id on a games row raised 42703 and blocked every deal on 31.10; read fields via jsonb
create or replace function public.award_halloween() returns trigger
language plpgsql security definer set search_path = public as $$
declare u uuid;
begin
  -- an achievement must never block a game: any error here is swallowed
  begin
    u := (to_jsonb(new) ->> case when tg_table_name = 'games' then 'host_id' else 'user_id' end)::uuid;
    if u is not null and (now() at time zone 'Asia/Bangkok')::date = date '2026-10-31' then
      insert into user_achievements (user_id, achievement_id) values (u, 'halloween-2026') on conflict do nothing;
    end if;
  exception when others then null;
  end;
  return new;
end $$;
drop trigger if exists seats_halloween on public.seats;
create trigger seats_halloween after insert on public.seats for each row execute function public.award_halloween();
drop trigger if exists games_halloween on public.games;
create trigger games_halloween after insert on public.games for each row execute function public.award_halloween();

-- whoever was already dealt today
insert into public.user_achievements (user_id, achievement_id)
select distinct x.u, 'halloween-2026' from (
  select s.user_id u from public.seats s join public.games g on g.id = s.game_id
  where (g.created_at at time zone 'Asia/Bangkok')::date = date '2026-10-31'
  union select g.host_id from public.games g where (g.created_at at time zone 'Asia/Bangkok')::date = date '2026-10-31'
) x where x.u is not null
on conflict do nothing;
