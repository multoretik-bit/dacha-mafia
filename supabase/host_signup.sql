-- DACHA 05.11: a host removes a no-show or adds someone who came without signing up (any date, also past)
create or replace function host_signup(g text, e uuid, u uuid, on_ boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if g = 'mafia' then
    if not can_host() then raise exception 'hosts only'; end if;
    if not exists (select 1 from events where id = e) then raise exception 'no date'; end if;
    if on_ then insert into signups (event_id, user_id, role) values (e, u, 'player') on conflict do nothing;
    else delete from signups where event_id = e and user_id = u; end if;
  elsif g in ('volley', 'foot') then
    if not can_sport_host(g) then raise exception 'hosts only'; end if;
    if not exists (select 1 from sport_events where id = e and sport = g) then raise exception 'no date'; end if;
    if on_ then insert into sport_signups (event_id, user_id, role) values (e, u, 'player') on conflict do nothing;
    else delete from sport_signups where event_id = e and user_id = u; end if;
  else raise exception 'bad game'; end if;
end $$;
revoke all on function host_signup(text, uuid, uuid, boolean) from public, anon;
grant execute on function host_signup(text, uuid, uuid, boolean) to authenticated;
