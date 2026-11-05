-- DACHA 05.11: events made by anybody (tea ceremony, chess…), checked automatically + approved by @tivishka,
-- one-off or weekly; sign-ups per date; notification preferences per person.

create table if not exists cevents (
  id uuid primary key default gen_random_uuid(),
  title text not null check (char_length(title) between 3 and 60),
  emoji text not null default '✨' check (char_length(emoji) <= 8),
  description text check (char_length(description) <= 600),
  day date not null,
  start_time time not null,
  weekly boolean not null default false,
  place_id uuid references places(id) on delete set null,
  place text check (char_length(place) <= 80),
  price int not null default 0 check (price between 0 and 10000),
  status text not null default 'pending' check (status in ('pending', 'approved', 'rejected', 'removed')),
  reject_reason text,
  created_by uuid not null references profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  decided_at timestamptz,
  announced_at timestamptz
);
create index if not exists cevents_status on cevents (status, day);

create table if not exists csignups (
  event_id uuid not null references cevents(id) on delete cascade,
  day date not null,
  user_id uuid not null references profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (event_id, day, user_id)
);

alter table cevents enable row level security;
alter table csignups enable row level security;
drop policy if exists "cevents visible" on cevents;
create policy "cevents visible" on cevents for select using (status = 'approved' or created_by = auth.uid() or can_grant_premium());
drop policy if exists "csignups visible" on csignups;
create policy "csignups visible" on csignups for select using (true);
drop policy if exists "csignup self" on csignups;
create policy "csignup self" on csignups for insert with check (
  user_id = auth.uid() and day >= bkk_today()
  and exists (select 1 from cevents e where e.id = event_id and e.status = 'approved'
              and (e.day = csignups.day or (e.weekly and csignups.day >= e.day and (csignups.day - e.day) % 7 = 0))));
drop policy if exists "csignup leave" on csignups;
create policy "csignup leave" on csignups for delete using (
  user_id = auth.uid() or exists (select 1 from cevents e where e.id = event_id and e.created_by = auth.uid()));

-- the bot's automatic check, then pending for @tivishka
create or replace function create_cevent(title text, emoji text, description text, day date, start_time time, weekly boolean, place_id uuid, place text, price int)
returns uuid language plpgsql security definer set search_path = public as $$
declare me_ uuid := auth.uid(); rid uuid; t text := trim(coalesce(title, '')); d text := trim(coalesce(description, ''));
begin
  if me_ is null then raise exception 'login'; end if;
  if char_length(t) < 3 then raise exception 'check: тема слишком короткая'; end if;
  if char_length(t) > 60 then raise exception 'check: тема длиннее 60 символов'; end if;
  if t !~ '[A-Za-zА-Яа-яЁё]{3,}' then raise exception 'check: в теме должно быть хоть одно слово'; end if;
  if (t || ' ' || d) ~* '(https?://|www\.|t\.me/|@[a-z0-9_]{4,}|bit\.ly)' then raise exception 'check: без ссылок и @упоминаний — контакт организатора и так виден'; end if;
  if (t || ' ' || d) ~* '(казино|ставк|крипт|заработ|инвест|займ|кредит|xxx|порно|наркот)' then raise exception 'check: похоже на рекламу или запрещённую тему'; end if;
  if t ~ '(.)\1{5,}' or d ~ '(.)\1{7,}' then raise exception 'check: слишком много повторов символов'; end if;
  if day < bkk_today() or day > bkk_today() + 90 then raise exception 'check: дата должна быть в ближайшие 3 месяца'; end if;
  if coalesce(price, 0) < 0 or coalesce(price, 0) > 10000 then raise exception 'check: цена от 0 до 10 000 ฿'; end if;
  if (select count(*) from cevents where created_by = me_ and status = 'pending') >= 3 then raise exception 'check: уже 3 ивента ждут проверки — дождись ответа'; end if;
  insert into cevents (title, emoji, description, day, start_time, weekly, place_id, place, price, created_by)
  values (t, coalesce(nullif(trim(emoji), ''), '✨'), nullif(d, ''), day, start_time, coalesce(weekly, false), place_id, nullif(trim(place), ''), coalesce(price, 0), me_)
  returning id into rid;
  return rid;
end $$;
revoke all on function create_cevent(text, text, text, date, time, boolean, uuid, text, int) from public, anon;
grant execute on function create_cevent(text, text, text, date, time, boolean, uuid, text, int) to authenticated;

-- organizer cancels his event
create or replace function remove_cevent(e uuid)
returns void language sql security definer set search_path = public as $$
  update cevents set status = 'removed' where id = e and (created_by = auth.uid() or can_grant_premium());
$$;
grant execute on function remove_cevent(uuid) to authenticated;

-- notification preferences: everything, or only chosen kinds (mafia / volley / foot / community)
alter table profiles add column if not exists notify_all boolean not null default true;
alter table profiles add column if not exists notify_kinds text[] not null default '{}';
create or replace function set_notify(all_ boolean, kinds text[])
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'login'; end if;
  update profiles set notify_all = coalesce(all_, true),
    notify_kinds = coalesce((select array_agg(k) from unnest(kinds) k where k in ('mafia', 'volley', 'foot', 'community')), '{}')
  where id = auth.uid();
end $$;
revoke all on function set_notify(boolean, text[]) from public, anon;
grant execute on function set_notify(boolean, text[]) to authenticated;

alter publication supabase_realtime add table cevents, csignups;
