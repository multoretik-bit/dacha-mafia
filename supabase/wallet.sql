-- DACHA wallet (05.11): one balance for every game.
-- balance = confirmed top-ups − charges. Everybody starts at 0 ฿.
-- A charge = the price of a date you were at (mafia: signed up, not as host; volleyball/football:
-- signed up or in the results), from 05.11.2026 on, once the date has started (Bangkok time).
-- Charges are computed, not stored: a host removing a no-show from the list removes the charge too.

create table if not exists wallet_tx (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references profiles(id) on delete cascade,
  amount int not null check (amount <> 0 and abs(amount) <= 1000000),
  method text not null check (method in ('qr', 'cash', 'adjust')),
  game text check (game in ('mafia', 'volley', 'foot')),
  event_id uuid,                                  -- events.id or sport_events.id (what it was paid for)
  status text not null default 'pending' check (status in ('pending', 'confirmed', 'rejected')),
  note text check (char_length(note) <= 200),
  created_by uuid references profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  decided_by uuid references profiles(id) on delete set null,
  decided_at timestamptz
);
create index if not exists wallet_tx_user on wallet_tx (user_id);
create index if not exists wallet_tx_event on wallet_tx (event_id);

alter table wallet_tx enable row level security;
drop policy if exists "wallet own or hosts" on wallet_tx;
create policy "wallet own or hosts" on wallet_tx for select using (user_id = auth.uid() or is_any_host());
-- writes only through the functions below

create or replace function wallet_charges_all()
returns table(user_id uuid, game text, event_id uuid, day date, start_time time, price int, place text)
language sql stable security definer set search_path = public as $$
  select s.user_id, 'mafia', e.id, e.day, e.start_time, e.price, pl.name
  from events e join signups s on s.event_id = e.id left join places pl on pl.id = e.place_id
  where e.status = 'open' and e.day >= date '2026-11-05' and e.price > 0
    and (e.day + e.start_time) <= (now() at time zone 'Asia/Bangkok')
    and not can_host(s.user_id)
  union all
  select x.user_id, e.sport, e.id, e.day, e.start_time, e.price, coalesce(pl.name, e.place)
  from sport_events e
  join (select event_id, user_id from sport_signups union select event_id, user_id from sport_results) x on x.event_id = e.id
  left join places pl on pl.id = e.place_id
  where e.status <> 'removed' and e.day >= date '2026-11-05' and e.price > 0
    and (e.day + e.start_time) <= (now() at time zone 'Asia/Bangkok');
$$;
revoke all on function wallet_charges_all() from public, anon, authenticated;

-- one person's wallet (self, or any host)
create or replace function wallet(u uuid default auth.uid())
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare ch jsonb; tx jsonb; paid int; owed int; pend int;
begin
  if u is null or (u <> auth.uid() and not is_any_host()) then raise exception 'not allowed'; end if;
  select coalesce(jsonb_agg(to_jsonb(c) order by c.day desc, c.start_time desc), '[]'), coalesce(sum(c.price), 0)
    into ch, owed from wallet_charges_all() c where c.user_id = u;
  select coalesce(jsonb_agg(to_jsonb(t) - 'user_id' order by t.created_at desc), '[]') into tx
    from (select * from wallet_tx where user_id = u order by created_at desc limit 200) t;
  select coalesce(sum(amount) filter (where status = 'confirmed'), 0), coalesce(sum(amount) filter (where status = 'pending'), 0)
    into paid, pend from wallet_tx where user_id = u;
  return jsonb_build_object('balance', paid - owed, 'pending', pend, 'paid', paid, 'owed', owed, 'charges', ch, 'txs', tx);
end $$;
grant execute on function wallet(uuid) to authenticated;

-- everybody's balance (hosts): debts on top
create or replace function wallet_balances()
returns table(user_id uuid, balance bigint, pending bigint)
language sql stable security definer set search_path = public as $$
  with c as (select user_id, sum(price) s from wallet_charges_all() group by 1),
       t as (select user_id, sum(amount) filter (where status = 'confirmed') ok, sum(amount) filter (where status = 'pending') pe from wallet_tx group by 1)
  select pr.id, coalesce(t.ok, 0) - coalesce(c.s, 0), coalesce(t.pe, 0)
  from profiles pr left join c on c.user_id = pr.id left join t on t.user_id = pr.id
  where is_any_host() and pr.tg_id is not null and (c.user_id is not null or t.user_id is not null);
$$;
grant execute on function wallet_balances() to authenticated;

-- player: "I transferred by QR" / "I'll give cash" (waits for a host)
create or replace function pay_request(amount int, m text, e uuid default null, g text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare id_ uuid;
begin
  if auth.uid() is null then raise exception 'login'; end if;
  if m not in ('qr', 'cash') then raise exception 'bad method'; end if;
  if amount is null or amount < 1 or amount > 100000 then raise exception 'bad amount'; end if;
  if g is not null and g not in ('mafia', 'volley', 'foot') then raise exception 'bad game'; end if;
  select id into id_ from wallet_tx where user_id = auth.uid() and status = 'pending' and event_id is not distinct from e limit 1;
  if id_ is not null then
    update wallet_tx set amount = pay_request.amount, method = m, game = coalesce(g, game), created_at = now() where id = id_;
  else
    insert into wallet_tx (user_id, amount, method, game, event_id, created_by) values (auth.uid(), amount, m, g, e, auth.uid()) returning id into id_;
  end if;
  return id_;
end $$;
grant execute on function pay_request(int, text, uuid, text) to authenticated;

create or replace function pay_cancel(tx uuid)
returns void language sql security definer set search_path = public as $$
  delete from wallet_tx where id = tx and user_id = auth.uid() and status = 'pending';
$$;
grant execute on function pay_cancel(uuid) to authenticated;

-- host: confirm / reject a request
create or replace function pay_decide(tx uuid, ok boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_any_host() then raise exception 'hosts only'; end if;
  update wallet_tx set status = case when ok then 'confirmed' else 'rejected' end, decided_by = auth.uid(), decided_at = now()
  where id = tx and status = 'pending';
end $$;
grant execute on function pay_decide(uuid, boolean) to authenticated;

-- host: "got N ฿ from this person" (already confirmed)
create or replace function pay_receive(u uuid, amount int, m text default 'cash', e uuid default null, g text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_any_host() then raise exception 'hosts only'; end if;
  if m not in ('qr', 'cash') or amount is null or amount < 1 or amount > 100000 then raise exception 'bad payment'; end if;
  insert into wallet_tx (user_id, amount, method, game, event_id, status, created_by, decided_by, decided_at)
  values (u, amount, m, g, e, 'confirmed', auth.uid(), auth.uid(), now());
end $$;
grant execute on function pay_receive(uuid, int, text, uuid, text) to authenticated;

-- @tivishka: correct a balance by hand (+ or −)
create or replace function wallet_adjust(u uuid, amount int, note text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not can_grant_premium() then raise exception 'only tivishka'; end if;
  insert into wallet_tx (user_id, amount, method, status, note, created_by, decided_by, decided_at)
  values (u, amount, 'adjust', 'confirmed', note, auth.uid(), auth.uid(), now());
end $$;
grant execute on function wallet_adjust(uuid, int, text) to authenticated;

alter publication supabase_realtime add table wallet_tx;

-- host: undo a mistaken "got it" (the money row stays, marked rejected)
create or replace function pay_undo(tx uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_any_host() then raise exception 'hosts only'; end if;
  update wallet_tx set status = 'rejected', decided_by = auth.uid(), decided_at = now()
  where id = tx and status in ('pending', 'confirmed') and method <> 'adjust';
end $$;
grant execute on function pay_undo(uuid) to authenticated;
