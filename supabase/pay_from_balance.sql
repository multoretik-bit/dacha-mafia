-- DACHA 05.11: pay any game from the app balance.
-- Paying marks the date as paid (wallet_tx purpose 'evpay', method 'balance') and reserves the price;
-- the money itself leaves the balance as usual when the date starts (the computed charge).
-- Leaving the date frees the reserve; nothing is lost.

alter table wallet_tx drop constraint if exists wallet_tx_method_check;
alter table wallet_tx add constraint wallet_tx_method_check check (method in ('qr', 'cash', 'adjust', 'transfer', 'balance'));
alter table wallet_tx drop constraint if exists wallet_tx_purpose_check;
alter table wallet_tx add constraint wallet_tx_purpose_check check (purpose in ('topup', 'premium', 'evpay'));

-- money set aside for dates paid from the balance that have not started yet (and you are still on)
create or replace function wallet_reserved(u uuid)
returns int language sql stable security definer set search_path = public as $$
  select coalesce(sum(t.amount), 0)::int from wallet_tx t
  where t.user_id = u and t.purpose = 'evpay' and t.status = 'confirmed'
    and not exists (select 1 from wallet_charges_all() c where c.user_id = u and c.event_id = t.event_id)
    and (exists (select 1 from signups s join events e on e.id = s.event_id where s.event_id = t.event_id and s.user_id = u and s.role = 'player' and e.status = 'open')
      or exists (select 1 from sport_signups s join sport_events e on e.id = s.event_id where s.event_id = t.event_id and s.user_id = u and s.role = 'player' and e.status <> 'removed'));
$$;
revoke all on function wallet_reserved(uuid) from public, anon, authenticated;

create or replace function wallet(u uuid default auth.uid())
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare ch jsonb; tx jsonb; paid int; owed int; pend int; res int;
begin
  if u is null or (u <> auth.uid() and not is_any_host()) then raise exception 'not allowed'; end if;
  select coalesce(jsonb_agg(to_jsonb(c) order by c.day desc, c.start_time desc), '[]'), coalesce(sum(c.price), 0)
    into ch, owed from wallet_charges_all() c where c.user_id = u;
  select coalesce(jsonb_agg(to_jsonb(t) - 'user_id' order by t.created_at desc), '[]') into tx
    from (select * from wallet_tx where user_id = u order by created_at desc limit 200) t;
  select coalesce(sum(amount) filter (where status = 'confirmed'), 0), coalesce(sum(amount) filter (where status = 'pending'), 0)
    into paid, pend from wallet_tx where user_id = u and purpose = 'topup';
  res := wallet_reserved(u);
  return jsonb_build_object('balance', paid - owed, 'reserved', res, 'available', paid - owed - res, 'pending', pend, 'paid', paid, 'owed', owed, 'charges', ch, 'txs', tx);
end $$;

create or replace function pay_from_balance(e uuid, g text)
returns uuid language plpgsql security definer set search_path = public as $$
declare me_ uuid := auth.uid(); pr int; av int; rid uuid;
begin
  if me_ is null then raise exception 'login'; end if;
  if g = 'mafia' then
    select price into pr from events where id = e and status = 'open';
    if not exists (select 1 from signups where event_id = e and user_id = me_ and role = 'player') then raise exception 'not signed up'; end if;
  elsif g in ('volley', 'foot') then
    select price into pr from sport_events where id = e and sport = g and status <> 'removed';
    if not exists (select 1 from sport_signups where event_id = e and user_id = me_ and role = 'player') then raise exception 'not signed up'; end if;
  else raise exception 'bad game'; end if;
  if pr is null or pr <= 0 then raise exception 'nothing to pay'; end if;
  if exists (select 1 from wallet_tx where user_id = me_ and event_id = e and status = 'confirmed' and purpose in ('topup', 'evpay')) then raise exception 'already paid'; end if;
  perform pg_advisory_xact_lock(hashtext(me_::text));
  av := (wallet(me_)->>'available')::int;
  if av < pr then raise exception 'not enough balance'; end if;
  insert into wallet_tx (user_id, amount, method, game, event_id, status, purpose, note, created_by, decided_by, decided_at)
  values (me_, pr, 'balance', g, e, 'confirmed', 'evpay', 'Оплата с баланса', me_, me_, now()) returning id into rid;
  return rid;
end $$;
revoke all on function pay_from_balance(uuid, text) from public, anon;
grant execute on function pay_from_balance(uuid, text) to authenticated;

-- transfers and PREMIUM from the balance may only use what is not reserved
create or replace function wallet_transfer(to_ uuid, amount int, note text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare me_ uuid := auth.uid(); av int; fn text; tn text; rid uuid;
begin
  if me_ is null then raise exception 'login'; end if;
  if to_ is null or to_ = me_ then raise exception 'bad recipient'; end if;
  if amount is null or amount < 1 or amount > 100000 then raise exception 'bad amount'; end if;
  if not exists (select 1 from profiles where id = to_ and tg_id is not null) then raise exception 'no such person'; end if;
  perform pg_advisory_xact_lock(hashtext(me_::text));
  av := (wallet(me_)->>'available')::int;
  if av < amount then raise exception 'not enough balance'; end if;
  select nick into fn from profiles where id = me_;
  select nick into tn from profiles where id = to_;
  insert into wallet_tx (user_id, amount, method, status, peer_id, note, created_by, decided_by, decided_at)
  values (me_, -amount, 'transfer', 'confirmed', to_, coalesce(nullif(trim(note), ''), 'Перевод → ' || tn), me_, me_, now());
  insert into wallet_tx (user_id, amount, method, status, peer_id, note, created_by, decided_by, decided_at)
  values (to_, amount, 'transfer', 'confirmed', me_, coalesce(nullif(trim(note), ''), 'Перевод от ' || fn), me_, me_, now()) returning id into rid;
  return rid;
end $$;

create or replace function premium_from_balance()
returns void language plpgsql security definer set search_path = public as $$
declare av int;
begin
  if auth.uid() is null then raise exception 'login'; end if;
  perform pg_advisory_xact_lock(hashtext(auth.uid()::text));
  av := (wallet(auth.uid())->>'available')::int;
  if av < premium_price('THB') then raise exception 'not enough balance'; end if;
  insert into wallet_tx (user_id, amount, method, status, note, created_by, decided_by, decided_at)
  values (auth.uid(), -premium_price('THB'), 'adjust', 'confirmed', 'PREMIUM на месяц', auth.uid(), auth.uid(), now());
  perform premium_extend(auth.uid());
end $$;
