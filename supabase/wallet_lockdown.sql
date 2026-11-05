-- DACHA 05.11 lockdown: ONLY @tivishka changes balances (credit, confirm top-ups, debts, write-offs, payouts).
-- Hosts only mark "paid for the game" (purpose 'gamepay') — a marker that never touches the balance.
-- People can still spend their own money: transfer, pay a game from the balance, buy PREMIUM, ask to withdraw.
-- Incident: 05.11 23:27 a mafia host credited himself 99 999 ฿ via pay_receive — reverted below.

alter table wallet_tx drop constraint if exists wallet_tx_purpose_check;
alter table wallet_tx add constraint wallet_tx_purpose_check check (purpose in ('topup', 'premium', 'evpay', 'withdraw', 'debt', 'gamepay'));

-- payments for a game are markers, not money in the app
update wallet_tx set purpose = 'gamepay' where purpose = 'topup' and event_id is not null;

-- revert the self-credit
update wallet_tx set status = 'rejected', note = 'Отменено: ведущий зачислил сам себе', decided_by = (select id from profiles where lower(tg_username) = 'tivishka'), decided_at = now()
where purpose = 'topup' and amount = 99999 and created_by = user_id and status = 'confirmed';

-- player: "I paid by QR / will give cash" — for a game it is a marker, otherwise a top-up request
create or replace function pay_request(amount int, m text, e uuid default null, g text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare id_ uuid; pur text := case when e is null then 'topup' else 'gamepay' end;
begin
  if auth.uid() is null then raise exception 'login'; end if;
  if m not in ('qr', 'cash') then raise exception 'bad method'; end if;
  if amount is null or amount < 1 or amount > 100000 then raise exception 'bad amount'; end if;
  if g is not null and g not in ('mafia', 'volley', 'foot') then raise exception 'bad game'; end if;
  select id into id_ from wallet_tx where user_id = auth.uid() and status = 'pending' and purpose = pur and event_id is not distinct from e limit 1;
  if id_ is not null then
    update wallet_tx set amount = pay_request.amount, method = m, game = coalesce(g, game), created_at = now() where id = id_;
  else
    insert into wallet_tx (user_id, amount, method, game, event_id, purpose, created_by) values (auth.uid(), amount, m, g, e, pur, auth.uid()) returning id into id_;
  end if;
  return id_;
end $$;

-- confirm / reject: game markers — hosts of that game (never their own); everything that moves money — only @tivishka
create or replace function pay_decide(tx uuid, ok boolean)
returns void language plpgsql security definer set search_path = public as $$
declare r wallet_tx;
begin
  select * into r from wallet_tx where id = tx and status = 'pending';
  if not found then return; end if;
  if r.purpose = 'gamepay' then
    if not (can_grant_premium() or (r.game = 'mafia' and can_host()) or (r.game in ('volley', 'foot') and can_sport_host(r.game))) then raise exception 'hosts only'; end if;
    if r.user_id = auth.uid() and not can_grant_premium() then raise exception 'not your own'; end if;
  elsif not can_grant_premium() then raise exception 'only tivishka';
  end if;
  update wallet_tx set status = case when ok then 'confirmed' else 'rejected' end, decided_by = auth.uid(), decided_at = now() where id = tx;
  if ok and r.purpose = 'premium' then perform premium_extend(r.user_id); end if;
end $$;

-- "got money": for a game — a marker by its host (not for himself); without a game — a real top-up, only @tivishka
create or replace function pay_receive(u uuid, amount int, m text default 'cash', e uuid default null, g text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare rid uuid;
begin
  if m not in ('qr', 'cash') or amount is null or amount < 1 or amount > 100000 then raise exception 'bad payment'; end if;
  if e is null then
    if not can_grant_premium() then raise exception 'only tivishka'; end if;
    insert into wallet_tx (user_id, amount, method, status, purpose, created_by, decided_by, decided_at)
    values (u, amount, m, 'confirmed', 'topup', auth.uid(), auth.uid(), now()) returning id into rid;
  else
    if not (can_grant_premium() or (g = 'mafia' and can_host()) or (g in ('volley', 'foot') and can_sport_host(g))) then raise exception 'hosts only'; end if;
    if u = auth.uid() and not can_grant_premium() then raise exception 'not your own'; end if;
    insert into wallet_tx (user_id, amount, method, game, event_id, status, purpose, created_by, decided_by, decided_at)
    values (u, amount, m, g, e, 'confirmed', 'gamepay', auth.uid(), auth.uid(), now()) returning id into rid;
  end if;
  return rid;
end $$;

create or replace function pay_undo(tx uuid)
returns void language plpgsql security definer set search_path = public as $$
declare r wallet_tx;
begin
  select * into r from wallet_tx where id = tx;
  if not found then return; end if;
  if r.purpose = 'gamepay' then
    if not (can_grant_premium() or (r.game = 'mafia' and can_host()) or (r.game in ('volley', 'foot') and can_sport_host(r.game))) then raise exception 'hosts only'; end if;
  elsif not can_grant_premium() then raise exception 'only tivishka';
  end if;
  update wallet_tx set status = 'rejected', decided_by = auth.uid(), decided_at = now() where id = tx and status in ('pending', 'confirmed') and method <> 'adjust';
end $$;

-- debts: only @tivishka
create or replace function host_debt(g text, e uuid, u uuid, on_ boolean)
returns void language plpgsql security definer set search_path = public as $$
declare pr int;
begin
  if not can_grant_premium() then raise exception 'only tivishka'; end if;
  if g = 'mafia' then select price into pr from events where id = e;
  elsif g in ('volley', 'foot') then select price into pr from sport_events where id = e and sport = g;
  else raise exception 'bad game'; end if;
  if pr is null or pr <= 0 then raise exception 'no price'; end if;
  if on_ then
    if not exists (select 1 from wallet_tx where user_id = u and event_id = e and purpose = 'debt') then
      insert into wallet_tx (user_id, amount, method, game, event_id, status, purpose, note, created_by, decided_by, decided_at)
      values (u, -pr, 'adjust', g, e, 'confirmed', 'debt', 'Долг за игру', auth.uid(), auth.uid(), now());
    end if;
  else
    delete from wallet_tx where user_id = u and event_id = e and purpose = 'debt';
  end if;
end $$;

-- paying a game from the balance is still possible; a game counts as paid by a confirmed marker too
create or replace function pay_from_balance(e uuid, g text)
returns uuid language plpgsql security definer set search_path = public as $$
declare me_ uuid := auth.uid(); pr int; av int; rid uuid; h uuid; mn text; hn text;
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
  h := date_host(g, e);
  if h is null then raise exception 'no host yet'; end if;
  if h = me_ then raise exception 'host cannot pay himself'; end if;
  if exists (select 1 from wallet_tx where user_id = me_ and event_id = e and status = 'confirmed' and (purpose = 'gamepay' or (purpose = 'evpay' and amount < 0))) then raise exception 'already paid'; end if;
  perform pg_advisory_xact_lock(hashtext(me_::text));
  av := (wallet(me_)->>'available')::int;
  if av < pr then raise exception 'not enough balance'; end if;
  select nick into mn from profiles where id = me_;
  select nick into hn from profiles where id = h;
  insert into wallet_tx (user_id, amount, method, game, event_id, status, purpose, peer_id, note, created_by, decided_by, decided_at)
  values (me_, -pr, 'balance', g, e, 'confirmed', 'evpay', h, 'Оплата игры → ' || coalesce(hn, 'ведущему'), me_, me_, now()) returning id into rid;
  insert into wallet_tx (user_id, amount, method, game, event_id, status, purpose, peer_id, note, created_by, decided_by, decided_at)
  values (h, pr, 'balance', g, e, 'confirmed', 'evpay', me_, 'Оплата за игру от ' || coalesce(mn, 'дачника'), me_, me_, now());
  delete from wallet_tx where user_id = me_ and event_id = e and purpose = 'debt';
  return rid;
end $$;
