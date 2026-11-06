-- DACHA 06.11: a tomato that hit nobody (app closed) waits for its target:
-- the bot writes to him, and on the next visit the screen is already splattered.
alter table tomato_throws add column if not exists seen_at timestamptz;
alter table tomato_throws add column if not exists notified_at timestamptz;
create index if not exists tomato_throws_unseen on tomato_throws (to_id) where seen_at is null;

-- the target marks tomatoes as "landed on my screen"
create or replace function tomato_seen(ids uuid[])
returns void language sql security definer set search_path = public as $$
  update tomato_throws set seen_at = now() where id = any(ids) and to_id = auth.uid() and seen_at is null;
$$;
revoke all on function tomato_seen(uuid[]) from public, anon;
grant execute on function tomato_seen(uuid[]) to authenticated;

-- old throws (before this change) count as seen
update tomato_throws set seen_at = created_at where seen_at is null and created_at < now() - interval '1 hour';
