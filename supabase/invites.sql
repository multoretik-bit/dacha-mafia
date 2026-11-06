-- DACHA 06.11: invitations inside the app ("Дениска зовёт тебя на пляж").
-- The invited person sees a notification and answers: accepted / declined / talk (a short reply to agree on details).
create table if not exists world_invites (
  id uuid primary key default gen_random_uuid(),
  from_id uuid not null references profiles(id) on delete cascade,
  to_id uuid not null references profiles(id) on delete cascade,
  what text not null check (char_length(what) between 1 and 60),
  status text not null default 'pending' check (status in ('pending', 'accepted', 'declined', 'talk')),
  reply text check (char_length(reply) <= 200),
  created_at timestamptz not null default now(),
  answered_at timestamptz,
  notified_at timestamptz
);
create index if not exists world_invites_to on world_invites (to_id, created_at desc);
create index if not exists world_invites_from on world_invites (from_id, created_at desc);
alter table world_invites enable row level security;
drop policy if exists "my invites" on world_invites;
create policy "my invites" on world_invites for select using (from_id = auth.uid() or to_id = auth.uid());

create or replace function invite_send(to_ uuid, what_ text) returns uuid language plpgsql security definer set search_path = public as $$
declare id_ uuid;
begin
  if not has_world() then raise exception 'no access'; end if;
  if to_ is null or to_ = auth.uid() or not exists (select 1 from profiles where id = to_ and tg_id is not null) then raise exception 'bad person'; end if;
  if (select count(*) from world_invites where from_id = auth.uid() and created_at > now() - interval '1 hour') >= 20 then raise exception 'too many'; end if;
  insert into world_invites (from_id, to_id, what) values (auth.uid(), to_, left(trim(what_), 60)) returning id into id_;
  return id_;
end $$;

create or replace function invite_answer(i uuid, st text, msg text default null) returns void language plpgsql security definer set search_path = public as $$
begin
  if st not in ('accepted', 'declined', 'talk') then raise exception 'bad answer'; end if;
  if st = 'talk' and coalesce(trim(msg), '') = '' then raise exception 'empty reply'; end if;
  update world_invites set status = st, reply = coalesce(nullif(left(trim(msg), 200), ''), reply), answered_at = now()
  where id = i and to_id = auth.uid() and created_at > now() - interval '3 days';
  if not found then raise exception 'not your invite'; end if;
end $$;

revoke all on function invite_send(uuid, text) from public, anon;
revoke all on function invite_answer(uuid, text, text) from public, anon;
grant execute on function invite_send(uuid, text) to authenticated;
grant execute on function invite_answer(uuid, text, text) to authenticated;
alter publication supabase_realtime add table world_invites;
