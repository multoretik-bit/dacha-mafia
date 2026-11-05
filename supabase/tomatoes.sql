-- DACHA 06.11: tomatoes. 3 free for everybody, then 1 ฿ each (the money goes to @tivishka for the app).
-- A throw splats on the target's screen if he is in the app (realtime INSERT on tomato_throws).

alter table profiles add column if not exists tomatoes int not null default 3 check (tomatoes >= 0);

create table if not exists tomato_throws (
  id uuid primary key default gen_random_uuid(),
  from_id uuid not null references profiles(id) on delete cascade,
  to_id uuid not null references profiles(id) on delete cascade,
  created_at timestamptz not null default now()
);
create index if not exists tomato_throws_from on tomato_throws (from_id, created_at desc);
alter table tomato_throws enable row level security;
drop policy if exists "tomatoes mine" on tomato_throws;
create policy "tomatoes mine" on tomato_throws for select using (to_id = auth.uid() or from_id = auth.uid());

create or replace function throw_tomato(to_ uuid)
returns int language plpgsql security definer set search_path = public as $$
declare me_ uuid := auth.uid(); left_ int;
begin
  if me_ is null then raise exception 'login'; end if;
  if to_ = me_ then raise exception 'self'; end if;
  if not exists (select 1 from profiles where id = to_ and tg_id is not null) then raise exception 'no such person'; end if;
  if exists (select 1 from tomato_throws where from_id = me_ and created_at > now() - interval '10 seconds') then raise exception 'too fast'; end if;
  update profiles set tomatoes = tomatoes - 1 where id = me_ and tomatoes > 0 returning tomatoes into left_;
  if left_ is null then raise exception 'no tomatoes'; end if;
  insert into tomato_throws (from_id, to_id) values (me_, to_);
  return left_;
end $$;
revoke all on function throw_tomato(uuid) from public, anon;
grant execute on function throw_tomato(uuid) to authenticated;

-- buy n tomatoes for n ฿ from your own balance; the baht go to @tivishka
create or replace function buy_tomatoes(n int)
returns int language plpgsql security definer set search_path = public as $$
declare me_ uuid := auth.uid(); av int; own uuid; mn text; total int;
begin
  if me_ is null then raise exception 'login'; end if;
  if n is null or n < 1 or n > 200 then raise exception 'bad amount'; end if;
  perform pg_advisory_xact_lock(hashtext(me_::text));
  av := (wallet(me_)->>'available')::int;
  if av < n then raise exception 'not enough balance'; end if;
  select id into own from profiles where lower(tg_username) = 'tivishka';
  select nick into mn from profiles where id = me_;
  if own is distinct from me_ then
    insert into wallet_tx (user_id, amount, method, status, purpose, peer_id, note, created_by, decided_by, decided_at)
    values (me_, -n, 'transfer', 'confirmed', 'topup', own, '🍅 ×' || n || ' — на развитие DACHA', me_, me_, now());
    insert into wallet_tx (user_id, amount, method, status, purpose, peer_id, note, created_by, decided_by, decided_at)
    values (own, n, 'transfer', 'confirmed', 'topup', me_, '🍅 ×' || n || ' от ' || coalesce(mn, 'дачника'), me_, me_, now());
  end if;
  update profiles set tomatoes = tomatoes + n where id = me_ returning tomatoes into total;
  return total;
end $$;
revoke all on function buy_tomatoes(int) from public, anon;
grant execute on function buy_tomatoes(int) to authenticated;

alter publication supabase_realtime add table tomato_throws;
