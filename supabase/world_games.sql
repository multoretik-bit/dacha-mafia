-- DACHA WORLD games (06.11): chess and checkers between two dachniki, live through realtime.
-- The board lives in `state`; whoever's turn it is sends the next state. A win gives +30 XP, a loss +10, a draw +15.
create table if not exists world_games (
  id uuid primary key default gen_random_uuid(),
  kind text not null check (kind in ('chess', 'checkers')),
  a uuid not null references profiles(id) on delete cascade,      -- the one who invited: plays white / first
  b uuid not null references profiles(id) on delete cascade,
  status text not null default 'invite' check (status in ('invite', 'active', 'done', 'declined')),
  state jsonb not null default '{}'::jsonb,
  turn uuid,
  ver int not null default 0,
  winner uuid,
  result text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists world_games_a on world_games (a, updated_at desc);
create index if not exists world_games_b on world_games (b, updated_at desc);
alter table world_games enable row level security;
drop policy if exists "my games" on world_games;
create policy "my games" on world_games for select using (a = auth.uid() or b = auth.uid());

create or replace function world_xp(u uuid, n int) returns void language sql security definer set search_path = public as $$
  insert into world_chars (user_id, xp) values (u, n) on conflict (user_id) do update set xp = world_chars.xp + n;
$$;
revoke all on function world_xp(uuid, int) from public, anon, authenticated;

create or replace function game_invite(k text, opp uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare id_ uuid;
begin
  if not has_world() then raise exception 'no access'; end if;
  if opp is null or opp = auth.uid() then raise exception 'bad opponent'; end if;
  if not exists (select 1 from world_members where user_id = opp)
     and not exists (select 1 from profiles where id = opp and lower(tg_username) = 'tivishka') then raise exception 'opponent closed'; end if;
  if (select count(*) from world_games where a = auth.uid() and status = 'invite' and created_at > now() - interval '1 hour') >= 10 then raise exception 'too many'; end if;
  insert into world_games (kind, a, b) values (k, auth.uid(), opp) returning id into id_;
  return id_;
end $$;

create or replace function game_answer(g uuid, ok boolean)
returns void language plpgsql security definer set search_path = public as $$
declare r world_games;
begin
  select * into r from world_games where id = g for update;
  if not found or r.b <> auth.uid() or r.status <> 'invite' then raise exception 'not your invite'; end if;
  update world_games set status = case when ok then 'active' else 'declined' end, turn = case when ok then r.a else null end, updated_at = now() where id = g;
end $$;

create or replace function game_move(g uuid, st jsonb, v int, fin text default null, win uuid default null)
returns void language plpgsql security definer set search_path = public as $$
declare r world_games; other uuid;
begin
  select * into r from world_games where id = g for update;
  if not found or auth.uid() not in (r.a, r.b) then raise exception 'not your game'; end if;
  if r.status <> 'active' then raise exception 'game over'; end if;
  if r.turn <> auth.uid() then raise exception 'not your turn'; end if;
  if r.ver <> v then raise exception 'stale'; end if;
  if st is null or pg_column_size(st) > 8000 then raise exception 'bad state'; end if;
  other := case when auth.uid() = r.a then r.b else r.a end;
  if fin is null then
    update world_games set state = st, ver = ver + 1, turn = other, updated_at = now() where id = g;
  else
    if fin not in ('win', 'draw') or (fin = 'win' and win not in (r.a, r.b)) then raise exception 'bad result'; end if;
    update world_games set state = st, ver = ver + 1, turn = null, status = 'done', result = fin, winner = case when fin = 'win' then win end, updated_at = now() where id = g;
    if fin = 'win' then perform world_xp(win, 30); perform world_xp(case when win = r.a then r.b else r.a end, 10);
    else perform world_xp(r.a, 15); perform world_xp(r.b, 15); end if;
  end if;
end $$;

create or replace function game_resign(g uuid)
returns void language plpgsql security definer set search_path = public as $$
declare r world_games; w uuid;
begin
  select * into r from world_games where id = g for update;
  if not found or auth.uid() not in (r.a, r.b) or r.status not in ('active', 'invite') then raise exception 'not your game'; end if;
  if r.status = 'invite' then update world_games set status = 'declined', updated_at = now() where id = g; return; end if;
  w := case when auth.uid() = r.a then r.b else r.a end;
  update world_games set status = 'done', result = 'resign', winner = w, turn = null, ver = ver + 1, updated_at = now() where id = g;
  perform world_xp(w, 30); perform world_xp(auth.uid(), 5);
end $$;

-- stats for the profile: level + wins per game
create or replace function world_card(u uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'xp', coalesce((select xp from world_chars where user_id = u), 0),
    'open', exists (select 1 from world_members where user_id = u) or exists (select 1 from profiles where id = u and lower(tg_username) = 'tivishka'),
    'chess_w', (select count(*) from world_games where kind = 'chess' and status = 'done' and winner = u),
    'chess_n', (select count(*) from world_games where kind = 'chess' and status = 'done' and u in (a, b)),
    'checkers_w', (select count(*) from world_games where kind = 'checkers' and status = 'done' and winner = u),
    'checkers_n', (select count(*) from world_games where kind = 'checkers' and status = 'done' and u in (a, b)))
$$;

revoke all on function game_invite(text, uuid) from public, anon;
revoke all on function game_answer(uuid, boolean) from public, anon;
revoke all on function game_move(uuid, jsonb, int, text, uuid) from public, anon;
revoke all on function game_resign(uuid) from public, anon;
revoke all on function world_card(uuid) from public, anon;
grant execute on function game_invite(text, uuid) to authenticated;
grant execute on function game_answer(uuid, boolean) to authenticated;
grant execute on function game_move(uuid, jsonb, int, text, uuid) to authenticated;
grant execute on function game_resign(uuid) to authenticated;
grant execute on function world_card(uuid) to authenticated;

alter publication supabase_realtime add table world_games;

-- who is in DACHA WORLD (to pick an opponent)
create or replace function world_people() returns setof uuid language sql stable security definer set search_path = public as $$
  select user_id from world_members where has_world()
  union select id from profiles where lower(tg_username) = 'tivishka' and has_world()
$$;
revoke all on function world_people() from public, anon;
grant execute on function world_people() to authenticated;
