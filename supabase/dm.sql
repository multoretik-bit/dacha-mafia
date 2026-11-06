-- DACHA 06.11: direct messages between dachniki inside the app.
-- A message not read within a few seconds is duplicated by the bot into the person's Telegram;
-- a Telegram reply to that bot message comes back into the chat (dm_messages.tg_msg_id maps it).
create table if not exists dm_messages (
  id uuid primary key default gen_random_uuid(),
  from_id uuid not null references profiles(id) on delete cascade,
  to_id uuid not null references profiles(id) on delete cascade,
  body text not null check (char_length(body) between 1 and 1000),
  created_at timestamptz not null default now(),
  read_at timestamptz,
  tg_msg_id bigint,
  via_tg boolean not null default false
);
create index if not exists dm_to on dm_messages (to_id, created_at desc);
create index if not exists dm_from on dm_messages (from_id, created_at desc);
create index if not exists dm_tg on dm_messages (tg_msg_id) where tg_msg_id is not null;
alter table dm_messages enable row level security;
drop policy if exists "my dms" on dm_messages;
create policy "my dms" on dm_messages for select using (from_id = auth.uid() or to_id = auth.uid());

create or replace function dm_send(to_ uuid, body_ text) returns uuid language plpgsql security definer set search_path = public as $$
declare id_ uuid; t text := left(trim(body_), 1000);
begin
  if not has_world() then raise exception 'no access'; end if;
  if t = '' then raise exception 'empty'; end if;
  if to_ is null or to_ = auth.uid() or not exists (select 1 from profiles where id = to_ and tg_id is not null) then raise exception 'bad person'; end if;
  if (select count(*) from dm_messages where from_id = auth.uid() and created_at > now() - interval '1 minute') >= 30 then raise exception 'too fast'; end if;
  insert into dm_messages (from_id, to_id, body) values (auth.uid(), to_, t) returning id into id_;
  return id_;
end $$;

create or replace function dm_read(peer uuid) returns void language sql security definer set search_path = public as $$
  update dm_messages set read_at = now() where to_id = auth.uid() and from_id = peer and read_at is null;
$$;

-- my conversations: the last message and how many are unread
create or replace function dm_threads() returns table (peer uuid, last_body text, last_at timestamptz, last_from uuid, unread int)
language sql stable security definer set search_path = public as $$
  with m as (
    select case when from_id = auth.uid() then to_id else from_id end as peer, body, created_at, from_id, to_id, read_at
    from dm_messages where from_id = auth.uid() or to_id = auth.uid()
  )
  select distinct on (peer) peer, body, created_at, from_id,
    (select count(*) from m m2 where m2.peer = m.peer and m2.to_id = auth.uid() and m2.read_at is null)::int
  from m order by peer, created_at desc
$$;

revoke all on function dm_send(uuid, text) from public, anon;
revoke all on function dm_read(uuid) from public, anon;
revoke all on function dm_threads() from public, anon;
grant execute on function dm_send(uuid, text) to authenticated;
grant execute on function dm_read(uuid) to authenticated;
grant execute on function dm_threads() to authenticated;
alter publication supabase_realtime add table dm_messages;
