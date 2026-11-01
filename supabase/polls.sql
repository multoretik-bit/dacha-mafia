-- 01.11.2026: polls through @dacha_gay («кто за мафию?»). @tivishka creates them in the app,
-- dachniks answer with buttons right in the bot, results are live in the app for hosts.
create table if not exists public.polls (
  id uuid primary key default gen_random_uuid(),
  question text not null check (length(question) between 1 and 300),
  options text[] not null check (cardinality(options) between 2 and 6),
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  closed_at timestamptz,
  test boolean not null default false,
  sent int not null default 0,
  total int not null default 0
);
create table if not exists public.poll_votes (
  poll_id uuid not null references public.polls(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  option int not null,
  voted_at timestamptz not null default now(),
  primary key (poll_id, user_id)
);
-- every bot message of a poll, so closing it can update them all
create table if not exists public.poll_msgs (
  poll_id uuid not null references public.polls(id) on delete cascade,
  chat_id bigint not null,
  message_id bigint not null,
  primary key (poll_id, chat_id)
);

alter table public.polls enable row level security;
alter table public.poll_votes enable row level security;
alter table public.poll_msgs enable row level security;
-- reads for hosts; all writes go through the tg edge function (service role)
drop policy if exists "polls read by hosts" on public.polls;
create policy "polls read by hosts" on public.polls for select to authenticated using (public.can_host());
drop policy if exists "poll votes read by hosts" on public.poll_votes;
create policy "poll votes read by hosts" on public.poll_votes for select to authenticated using (public.can_host());

do $$ begin
  alter publication supabase_realtime add table public.poll_votes;
exception when duplicate_object then null; end $$;
