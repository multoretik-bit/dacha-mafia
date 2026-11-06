-- DACHA WORLD (06.11, step 1): a map of the dacha (Phuket first) with everyone's mini character,
-- live location by choice, what you're doing, care & levels, a rating. Closed: @tivishka + world_members.

create table if not exists world_members (
  user_id uuid primary key references profiles(id) on delete cascade,
  added_at timestamptz not null default now()
);
alter table world_members enable row level security;
drop policy if exists "world members read" on world_members;
create policy "world members read" on world_members for select using (user_id = auth.uid() or can_grant_premium());

create or replace function has_world() returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(can_grant_premium(), false) or exists (select 1 from world_members where user_id = auth.uid())
$$;
revoke all on function has_world() from public, anon;
grant execute on function has_world() to authenticated;

-- the character: look (skin, hair, beard, glasses, outfit, background), care timestamps, experience
create table if not exists world_chars (
  user_id uuid primary key references profiles(id) on delete cascade,
  name text check (char_length(name) <= 24),
  look jsonb not null default '{}'::jsonb,
  xp int not null default 0,
  fed_at timestamptz not null default now(),
  washed_at timestamptz not null default now(),
  played_at timestamptz not null default now(),
  slept_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);
alter table world_chars enable row level security;
drop policy if exists "world chars read" on world_chars;
create policy "world chars read" on world_chars for select using (has_world());

-- where you are and what you're doing (only while you share it)
create table if not exists world_presence (
  user_id uuid primary key references profiles(id) on delete cascade,
  lat double precision, lng double precision,
  status text check (char_length(status) <= 60),
  emoji text check (char_length(emoji) <= 8),
  visible boolean not null default true,
  updated_at timestamptz not null default now()
);
alter table world_presence enable row level security;
drop policy if exists "world presence read" on world_presence;
create policy "world presence read" on world_presence for select using (has_world() and (visible or user_id = auth.uid()));

create or replace function world_save_char(nm text, lk jsonb)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not has_world() then raise exception 'no access'; end if;
  if lk is null or jsonb_typeof(lk) <> 'object' or pg_column_size(lk) > 1500 then raise exception 'bad look'; end if;
  insert into world_chars (user_id, name, look, fed_at, washed_at, played_at, slept_at)   -- a newborn is a bit hungry: care right away
  values (auth.uid(), nullif(trim(nm), ''), lk, now() - interval '7 hours', now() - interval '9 hours', now() - interval '3 hours', now() - interval '10 hours')
  on conflict (user_id) do update set name = excluded.name, look = excluded.look;
end $$;

-- care: feed / wash / play / sleep — each has its own cooldown and gives experience
create or replace function world_care(a text)
returns world_chars language plpgsql security definer set search_path = public as $$
declare c world_chars; cd interval; gain int;
begin
  if not has_world() then raise exception 'no access'; end if;
  select * into c from world_chars where user_id = auth.uid() for update;
  if not found then raise exception 'no character'; end if;
  case a
    when 'feed'  then cd := interval '45 minutes'; gain := 10; if c.fed_at    > now() - cd then raise exception 'cooldown'; end if; update world_chars set fed_at = now(),    xp = xp + gain where user_id = auth.uid();
    when 'wash'  then cd := interval '90 minutes'; gain := 10; if c.washed_at > now() - cd then raise exception 'cooldown'; end if; update world_chars set washed_at = now(), xp = xp + gain where user_id = auth.uid();
    when 'play'  then cd := interval '30 minutes'; gain := 15; if c.played_at > now() - cd then raise exception 'cooldown'; end if; update world_chars set played_at = now(), xp = xp + gain where user_id = auth.uid();
    when 'sleep' then cd := interval '4 hours';    gain := 8;  if c.slept_at  > now() - cd then raise exception 'cooldown'; end if; update world_chars set slept_at = now(),  xp = xp + gain where user_id = auth.uid();
    else raise exception 'bad action';
  end case;
  select * into c from world_chars where user_id = auth.uid();
  return c;
end $$;

create or replace function world_here(la double precision, ln double precision, st text, em text, vis boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not has_world() then raise exception 'no access'; end if;
  if la is not null and (la < -90 or la > 90 or ln < -180 or ln > 180) then raise exception 'bad place'; end if;
  insert into world_presence (user_id, lat, lng, status, emoji, visible, updated_at)
  values (auth.uid(), la, ln, nullif(trim(st), ''), nullif(trim(em), ''), coalesce(vis, true), now())
  on conflict (user_id) do update set
    lat = coalesce(excluded.lat, world_presence.lat), lng = coalesce(excluded.lng, world_presence.lng),
    status = excluded.status, emoji = excluded.emoji, visible = excluded.visible, updated_at = now();
end $$;

-- @tivishka opens the world to someone (or closes it)
create or replace function world_grant(u uuid, on_ boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not can_grant_premium() then raise exception 'only tivishka'; end if;
  if on_ then insert into world_members (user_id) values (u) on conflict do nothing;
  else delete from world_members where user_id = u; delete from world_presence where user_id = u; end if;
end $$;

revoke all on function world_save_char(text, jsonb) from public, anon;
revoke all on function world_care(text) from public, anon;
revoke all on function world_here(double precision, double precision, text, text, boolean) from public, anon;
revoke all on function world_grant(uuid, boolean) from public, anon;
grant execute on function world_save_char(text, jsonb) to authenticated;
grant execute on function world_care(text) to authenticated;
grant execute on function world_here(double precision, double precision, text, text, boolean) to authenticated;
grant execute on function world_grant(uuid, boolean) to authenticated;

alter publication supabase_realtime add table world_presence;
alter publication supabase_realtime add table world_chars;
