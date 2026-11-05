-- DACHA 05.11: each host's own QR + "I host" / "I play" on a date

-- own QR for payments (hosts and @tivishka); shown when paying for a date this person hosts
alter table profiles add column if not exists pay_qr text check (pay_qr is null or pay_qr ~* '^https://');
create or replace function set_pay_qr(url text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_any_host() then raise exception 'hosts only'; end if;
  if url is not null and url !~* '^https://' then raise exception 'bad url'; end if;
  update profiles set pay_qr = nullif(url, '') where id = auth.uid();
end $$;
revoke all on function set_pay_qr(text) from public, anon;
grant execute on function set_pay_qr(text) to authenticated;

-- every host (mafia, volleyball, football) may upload a QR picture
drop policy if exists "any host uploads pay qr" on storage.objects;
create policy "any host uploads pay qr" on storage.objects for insert to authenticated
  with check (bucket_id = 'pay' and public.is_any_host());

-- role on a date: player (pays) or host (leads, does not pay)
alter table signups add column if not exists role text not null default 'player' check (role in ('player', 'host'));
alter table sport_signups add column if not exists role text not null default 'player' check (role in ('player', 'host'));
-- until now every mafia host's sign-up meant "I host"
update signups s set role = 'host' from profiles pr join host_allowlist h on h.tg_username = lower(pr.tg_username) where pr.id = s.user_id and s.role = 'player';

-- only a host of that game may sign up as host
create or replace function signup_role_guard()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.role = 'host' then
    if tg_table_name = 'signups' and not can_host(new.user_id) then raise exception 'only hosts can host'; end if;
    if tg_table_name = 'sport_signups' and not can_sport_host((select sport from sport_events where id = new.event_id), new.user_id) then raise exception 'only hosts can host'; end if;
  end if;
  return new;
end $$;
drop trigger if exists signup_role_guard on signups;
create trigger signup_role_guard before insert or update of role on signups for each row execute function signup_role_guard();
drop trigger if exists signup_role_guard on sport_signups;
create trigger signup_role_guard before insert or update of role on sport_signups for each row execute function signup_role_guard();

-- charges: the price for everybody who played (hosts of the date don't pay)
create or replace function wallet_charges_all()
returns table(user_id uuid, game text, event_id uuid, day date, start_time time, price int, place text)
language sql stable security definer set search_path = public as $$
  select s.user_id, 'mafia', e.id, e.day, e.start_time, e.price, pl.name
  from events e join signups s on s.event_id = e.id and s.role = 'player' left join places pl on pl.id = e.place_id
  where e.status = 'open' and e.day >= date '2026-11-05' and e.price > 0
    and (e.day + e.start_time) <= (now() at time zone 'Asia/Bangkok')
  union all
  select x.user_id, e.sport, e.id, e.day, e.start_time, e.price, coalesce(pl.name, e.place)
  from sport_events e
  join (select event_id, user_id from sport_signups where role = 'player'
        union select r.event_id, r.user_id from sport_results r
              where not exists (select 1 from sport_signups h where h.event_id = r.event_id and h.user_id = r.user_id and h.role = 'host')) x on x.event_id = e.id
  left join places pl on pl.id = e.place_id
  where e.status <> 'removed' and e.day >= date '2026-11-05' and e.price > 0
    and (e.day + e.start_time) <= (now() at time zone 'Asia/Bangkok');
$$;
revoke all on function wallet_charges_all() from public, anon, authenticated;
