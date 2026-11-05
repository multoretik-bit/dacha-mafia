-- DACHA 05.11: buying PREMIUM (1 month): 400 ฿ (QR / cash), 1000 ₽ or 12 $ (transfer via @tivishka).
-- A purchase is a wallet_tx with purpose = 'premium'; it never touches the game balance.
-- Only @tivishka confirms it; on confirm PREMIUM is extended by a month.

alter table wallet_tx add column if not exists purpose text not null default 'topup' check (purpose in ('topup', 'premium'));
alter table wallet_tx add column if not exists currency text not null default 'THB' check (currency in ('THB', 'RUB', 'USD'));
alter table wallet_tx drop constraint if exists wallet_tx_method_check;
alter table wallet_tx add constraint wallet_tx_method_check check (method in ('qr', 'cash', 'adjust', 'transfer'));

create or replace function premium_price(cur text) returns int language sql immutable as $$
  select case cur when 'THB' then 400 when 'RUB' then 1000 when 'USD' then 12 end;
$$;

-- extend by one month (forever stays forever)
create or replace function premium_extend(u uuid) returns void language sql security definer set search_path = public as $$
  update profiles set premium_until = case
      when premium_until = 'infinity' then premium_until
      else greatest(coalesce(premium_until, now()), now()) + interval '1 month' end
  where id = u;
$$;
revoke all on function premium_extend(uuid) from public, anon, authenticated;

-- player: "I paid for PREMIUM" (waits for @tivishka)
create or replace function premium_request(cur text, m text)
returns uuid language plpgsql security definer set search_path = public as $$
declare id_ uuid; pr int := premium_price(cur);
begin
  if auth.uid() is null then raise exception 'login'; end if;
  if pr is null then raise exception 'bad currency'; end if;
  if (cur = 'THB' and m not in ('qr', 'cash')) or (cur <> 'THB' and m <> 'transfer') then raise exception 'bad method'; end if;
  select id into id_ from wallet_tx where user_id = auth.uid() and purpose = 'premium' and status = 'pending' limit 1;
  if id_ is not null then
    update wallet_tx set amount = pr, currency = cur, method = m, created_at = now() where id = id_;
  else
    insert into wallet_tx (user_id, amount, method, currency, purpose, note, created_by)
    values (auth.uid(), pr, m, cur, 'premium', 'PREMIUM на месяц', auth.uid()) returning id into id_;
  end if;
  return id_;
end $$;
grant execute on function premium_request(text, text) to authenticated;

-- player: pay PREMIUM from a positive balance (instant)
create or replace function premium_from_balance()
returns void language plpgsql security definer set search_path = public as $$
declare bal int;
begin
  if auth.uid() is null then raise exception 'login'; end if;
  bal := (wallet(auth.uid())->>'balance')::int;
  if bal < premium_price('THB') then raise exception 'not enough balance'; end if;
  insert into wallet_tx (user_id, amount, method, status, note, created_by, decided_by, decided_at)
  values (auth.uid(), -premium_price('THB'), 'adjust', 'confirmed', 'PREMIUM на месяц', auth.uid(), auth.uid(), now());
  perform premium_extend(auth.uid());
end $$;
grant execute on function premium_from_balance() to authenticated;

-- confirm / reject: premium only by @tivishka; confirming premium switches it on
create or replace function pay_decide(tx uuid, ok boolean)
returns void language plpgsql security definer set search_path = public as $$
declare r wallet_tx;
begin
  select * into r from wallet_tx where id = tx and status = 'pending';
  if not found then return; end if;
  if r.purpose = 'premium' then
    if not can_grant_premium() then raise exception 'only tivishka'; end if;
  elsif not is_any_host() then raise exception 'hosts only'; end if;
  update wallet_tx set status = case when ok then 'confirmed' else 'rejected' end, decided_by = auth.uid(), decided_at = now() where id = tx;
  if ok and r.purpose = 'premium' then perform premium_extend(r.user_id); end if;
end $$;

-- balance counts only game money (purpose topup, baht)
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
    into paid, pend from wallet_tx where user_id = u and purpose = 'topup';
  return jsonb_build_object('balance', paid - owed, 'pending', pend, 'paid', paid, 'owed', owed, 'charges', ch, 'txs', tx);
end $$;

create or replace function wallet_balances()
returns table(user_id uuid, balance bigint, pending bigint)
language sql stable security definer set search_path = public as $$
  with c as (select user_id, sum(price) s from wallet_charges_all() group by 1),
       t as (select user_id, sum(amount) filter (where status = 'confirmed') ok, sum(amount) filter (where status = 'pending') pe from wallet_tx where purpose = 'topup' group by 1)
  select pr.id, coalesce(t.ok, 0) - coalesce(c.s, 0), coalesce(t.pe, 0)
  from profiles pr left join c on c.user_id = pr.id left join t on t.user_id = pr.id
  where is_any_host() and pr.tg_id is not null and (c.user_id is not null or t.user_id is not null);
$$;

-- a top-up request must never overwrite a pending PREMIUM purchase
create or replace function pay_request(amount int, m text, e uuid default null, g text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare id_ uuid;
begin
  if auth.uid() is null then raise exception 'login'; end if;
  if m not in ('qr', 'cash') then raise exception 'bad method'; end if;
  if amount is null or amount < 1 or amount > 100000 then raise exception 'bad amount'; end if;
  if g is not null and g not in ('mafia', 'volley', 'foot') then raise exception 'bad game'; end if;
  select id into id_ from wallet_tx where user_id = auth.uid() and status = 'pending' and purpose = 'topup' and event_id is not distinct from e limit 1;
  if id_ is not null then
    update wallet_tx set amount = pay_request.amount, method = m, game = coalesce(g, game), created_at = now() where id = id_;
  else
    insert into wallet_tx (user_id, amount, method, game, event_id, created_by) values (auth.uid(), amount, m, g, e, auth.uid()) returning id into id_;
  end if;
  return id_;
end $$;
