-- DACHA 05.11: sport results are counts per person per day: how many games won / lost (/ drawn)

alter table sport_results add column if not exists wins int not null default 0 check (wins between 0 and 99);
alter table sport_results add column if not exists losses int not null default 0 check (losses between 0 and 99);
alter table sport_results add column if not exists draws int not null default 0 check (draws between 0 and 99);
update sport_results set wins = (result = 'win')::int, losses = (result = 'loss')::int, draws = (result = 'draw')::int where wins + losses + draws = 0;

-- rows = [{u, w, l, d}]; a person with all zeros is dropped
create or replace function save_sport_results(e uuid, rows jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare sp text;
begin
  select sport into sp from sport_events where id = e;
  if sp is null then raise exception 'no event'; end if;
  if not can_sport_host(sp) then raise exception 'only sport host'; end if;
  delete from sport_results where event_id = e;
  insert into sport_results (event_id, user_id, wins, losses, draws, result, set_by)
    select e, (x->>'u')::uuid, greatest(0, least(99, coalesce((x->>'w')::int, 0))), greatest(0, least(99, coalesce((x->>'l')::int, 0))), greatest(0, least(99, coalesce((x->>'d')::int, 0))),
      case when coalesce((x->>'w')::int, 0) > coalesce((x->>'l')::int, 0) then 'win' when coalesce((x->>'l')::int, 0) > coalesce((x->>'w')::int, 0) then 'loss' else 'draw' end,
      auth.uid()
    from jsonb_array_elements(rows) x
    where coalesce((x->>'w')::int, 0) + coalesce((x->>'l')::int, 0) + coalesce((x->>'d')::int, 0) > 0;
  update sport_events set status = case when exists (select 1 from sport_results where event_id = e) then 'done' else 'open' end where id = e and status <> 'removed';
end $$;

-- rating: wins and losses are summed over the days; games = all games played
create or replace function sport_board(s text, m date default null)
returns table(id uuid, nick text, color text, tg_username text, tg_name text, tg_photo text, games bigint, wins bigint, losses bigint, draws bigint)
language sql stable security definer set search_path = public as $$
  select pr.id, pr.nick, pr.color, pr.tg_username, pr.tg_name, pr.tg_photo,
    sum(r.wins + r.losses + r.draws), sum(r.wins), sum(r.losses), sum(r.draws)
  from sport_results r
  join sport_events e on e.id = r.event_id and e.status <> 'removed' and e.sport = s
  join profiles pr on pr.id = r.user_id
  where m is null or date_trunc('month', e.day)::date = m
  group by pr.id
  order by 8 desc, 7 desc, 2;
$$;

create or replace function sport_stats(p uuid)
returns table(sport text, games bigint, wins bigint, losses bigint, draws bigint, place bigint)
language sql stable security definer set search_path = public as $$
  with b as (
    select e.sport, r.user_id, sum(r.wins + r.losses + r.draws) g, sum(r.wins) w, sum(r.losses) l, sum(r.draws) d
    from sport_results r join sport_events e on e.id = r.event_id and e.status <> 'removed'
    group by 1, 2
  ), ranked as (select *, rank() over (partition by sport order by w desc, g desc) rk from b)
  select sport, g, w, l, d, rk from ranked where user_id = p;
$$;
