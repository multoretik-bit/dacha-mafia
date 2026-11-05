-- DACHA 05.11: cash-out requests. A pending withdrawal blocks the money; @tivishka pays out and confirms.

alter table wallet_tx drop constraint if exists wallet_tx_method_check;
alter table wallet_tx add constraint wallet_tx_method_check check (method in ('qr', 'cash', 'adjust', 'transfer', 'balance', 'withdraw'));
alter table wallet_tx drop constraint if exists wallet_tx_purpose_check;
alter table wallet_tx add constraint wallet_tx_purpose_check check (purpose in ('topup', 'premium', 'evpay', 'withdraw'));

create or replace function wallet(u uuid default auth.uid())
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare ch jsonb; tx jsonb; paid int; owed int; pend int; res int; wd int;
begin
  if u is null or (u <> auth.uid() and not is_any_host()) then raise exception 'not allowed'; end if;
  select coalesce(jsonb_agg(to_jsonb(c) order by c.day desc, c.start_time desc), '[]'), coalesce(sum(c.price), 0)
    into ch, owed from wallet_charges_all() c where c.user_id = u;
  select coalesce(jsonb_agg(to_jsonb(t) - 'user_id' order by t.created_at desc), '[]') into tx
    from (select * from wallet_tx where user_id = u order by created_at desc limit 200) t;
  select coalesce(sum(amount) filter (where status = 'confirmed' and purpose in ('topup', 'withdraw')), 0),
         coalesce(sum(amount) filter (where status = 'pending' and purpose = 'topup'), 0),
         coalesce(-sum(amount) filter (where status = 'pending' and purpose = 'withdraw'), 0)
    into paid, pend, wd from wallet_tx where user_id = u;
  res := wallet_reserved(u);
  return jsonb_build_object('balance', paid - owed, 'reserved', res, 'withdrawing', wd, 'available', paid - owed - res - wd,
    'pending', pend, 'paid', paid, 'owed', owed, 'charges', ch, 'txs', tx);
end $$;

create or replace function wallet_balances()
returns table(user_id uuid, balance bigint, pending bigint)
language sql stable security definer set search_path = public as $$
  with c as (select user_id, sum(price) s from wallet_charges_all() group by 1),
       t as (select user_id, sum(amount) filter (where status = 'confirmed' and purpose in ('topup', 'withdraw')) ok,
                    sum(amount) filter (where status = 'pending' and purpose = 'topup') pe from wallet_tx group by 1)
  select pr.id, coalesce(t.ok, 0) - coalesce(c.s, 0), coalesce(t.pe, 0)
  from profiles pr left join c on c.user_id = pr.id left join t on t.user_id = pr.id
  where is_any_host() and pr.tg_id is not null and (c.user_id is not null or t.user_id is not null);
$$;

create or replace function withdraw_request(amount int, details text)
returns uuid language plpgsql security definer set search_path = public as $$
declare me_ uuid := auth.uid(); av int; rid uuid;
begin
  if me_ is null then raise exception 'login'; end if;
  if amount is null or amount < 1 or amount > 100000 then raise exception 'bad amount'; end if;
  if coalesce(trim(details), '') = '' then raise exception 'details needed'; end if;
  perform pg_advisory_xact_lock(hashtext(me_::text));
  av := (wallet(me_)->>'available')::int;
  if av < amount then raise exception 'not enough balance'; end if;
  insert into wallet_tx (user_id, amount, method, purpose, status, note, created_by)
  values (me_, -amount, 'withdraw', 'withdraw', 'pending', left(trim(details), 200), me_) returning id into rid;
  return rid;
end $$;
revoke all on function withdraw_request(int, text) from public, anon;
grant execute on function withdraw_request(int, text) to authenticated;

-- premium and withdrawals: only @tivishka decides
create or replace function pay_decide(tx uuid, ok boolean)
returns void language plpgsql security definer set search_path = public as $$
declare r wallet_tx;
begin
  select * into r from wallet_tx where id = tx and status = 'pending';
  if not found then return; end if;
  if r.purpose in ('premium', 'withdraw') then
    if not can_grant_premium() then raise exception 'only tivishka'; end if;
  elsif not is_any_host() then raise exception 'hosts only'; end if;
  update wallet_tx set status = case when ok then 'confirmed' else 'rejected' end, decided_by = auth.uid(), decided_at = now() where id = tx;
  if ok and r.purpose = 'premium' then perform premium_extend(r.user_id); end if;
end $$;
