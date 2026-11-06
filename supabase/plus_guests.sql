-- DACHA 06.11: "+1" — a player says he comes with 1–3 friends; shown next to his name, counted in "N идут"
alter table signups add column if not exists plus smallint not null default 0 check (plus between 0 and 3);
alter table sport_signups add column if not exists plus smallint not null default 0 check (plus between 0 and 3);

create or replace function set_plus(g text, e uuid, n int)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'login'; end if;
  if n is null or n < 0 or n > 3 then raise exception 'bad number'; end if;
  if g = 'mafia' then
    update signups set plus = n where event_id = e and user_id = auth.uid() and role = 'player';
  elsif g in ('volley', 'foot') then
    update sport_signups set plus = n where event_id = e and user_id = auth.uid() and role = 'player';
  else raise exception 'bad game'; end if;
  if not found then raise exception 'not signed up'; end if;
end $$;
revoke all on function set_plus(text, uuid, int) from public, anon;
grant execute on function set_plus(text, uuid, int) to authenticated;
