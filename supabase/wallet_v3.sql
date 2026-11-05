-- DACHA 05.11 (v3): no automatic charges. The balance changes only by real money moves:
-- top-ups, transfers, withdrawals, PREMIUM, paying a game from the balance (goes to the host at once),
-- and a DEBT that a host / @tivishka puts on purpose ("не заплатил → в долг").
-- Balance −1000 ฿ or lower blocks the person (no sign-ups, no announcements, app shows "пополни").

alter table wallet_tx drop constraint if exists wallet_tx_purpose_check;
alter table wallet_tx add constraint wallet_tx_purpose_check check (purpose in ('topup', 'premium', 'evpay', 'withdraw', 'debt'));

create or replace function wallet_sum(u uuid)
returns int language sql stable security definer set search_path = public as $$
  select coalesce(sum(amount), 0)::int from wallet_tx where user_id = u and status = 'confirmed' and purpose in ('topup', 'withdraw', 'evpay', 'debt');
$$;
revoke all on function wallet_sum(uuid) from public, anon, authenticated;

create or replace function wallet(u uuid default auth.uid())
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare tx jsonb; bal int; pend int; wd int; debt int;
begin
  if u is null or (u <> auth.uid() and not is_any_host()) then raise exception 'not allowed'; end if;
  select coalesce(jsonb_agg(to_jsonb(t) - 'user_id' order by t.created_at desc), '[]') into tx
    from (select * from wallet_tx where user_id = u order by created_at desc limit 200) t;
  bal := wallet_sum(u);
  select coalesce(sum(amount) filter (where status = 'pending' and purpose = 'topup'), 0),
         coalesce(-sum(amount) filter (where status = 'pending' and purpose = 'withdraw'), 0),
         coalesce(-sum(amount) filter (where status = 'confirmed' and purpose = 'debt'), 0)
    into pend, wd, debt from wallet_tx where user_id = u;
  return jsonb_build_object('balance', bal, 'reserved', 0, 'withdrawing', wd, 'available', bal - wd, 'pending', pend,
    'paid', bal + debt, 'owed', debt, 'earned', 0, 'income', '[]'::jsonb, 'charges', '[]'::jsonb, 'txs', tx, 'blocked', bal <= -1000);
end $$;

create or replace function wallet_balances()
returns table(user_id uuid, balance bigint, pending bigint)
language sql stable security definer set search_path = public as $$
  select t.user_id, coalesce(sum(t.amount) filter (where t.status = 'confirmed' and t.purpose in ('topup', 'withdraw', 'evpay', 'debt')), 0),
         coalesce(sum(t.amount) filter (where t.status = 'pending' and t.purpose = 'topup'), 0)
  from wallet_tx t join profiles pr on pr.id = t.user_id
  where is_any_host() and pr.tg_id is not null
  group by t.user_id;
$$;

create or replace function blocked_ids()
returns setof uuid language sql stable security definer set search_path = public as $$
  select user_id from wallet_tx where status = 'confirmed' and purpose in ('topup', 'withdraw', 'evpay', 'debt')
  group by user_id having sum(amount) <= -1000;
$$;
revoke all on function blocked_ids() from public, anon;
grant execute on function blocked_ids() to authenticated;

create or replace function is_blocked(u uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select wallet_sum(u) <= -1000;
$$;

-- paying a game from the balance moves the money to the host right away
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
  if exists (select 1 from wallet_tx where user_id = me_ and event_id = e and status = 'confirmed' and (purpose = 'topup' or (purpose = 'evpay' and amount < 0))) then raise exception 'already paid'; end if;
  perform pg_advisory_xact_lock(hashtext(me_::text));
  av := (wallet(me_)->>'available')::int;
  if av < pr then raise exception 'not enough balance'; end if;
  select nick into mn from profiles where id = me_;
  select nick into hn from profiles where id = h;
  insert into wallet_tx (user_id, amount, method, game, event_id, status, purpose, peer_id, note, created_by, decided_by, decided_at)
  values (me_, -pr, 'balance', g, e, 'confirmed', 'evpay', h, 'Оплата игры → ' || coalesce(hn, 'ведущему'), me_, me_, now()) returning id into rid;
  insert into wallet_tx (user_id, amount, method, game, event_id, status, purpose, peer_id, note, created_by, decided_by, decided_at)
  values (h, pr, 'balance', g, e, 'confirmed', 'evpay', me_, 'Оплата за игру от ' || coalesce(mn, 'дачника'), me_, me_, now());
  -- a debt for this game is settled by the payment
  delete from wallet_tx where user_id = me_ and event_id = e and purpose = 'debt';
  return rid;
end $$;

-- host / @tivishka: "didn't pay → put in debt" (or remove the debt)
create or replace function host_debt(g text, e uuid, u uuid, on_ boolean)
returns void language plpgsql security definer set search_path = public as $$
declare pr int;
begin
  if g = 'mafia' then
    if not can_host() then raise exception 'hosts only'; end if;
    select price into pr from events where id = e;
  elsif g in ('volley', 'foot') then
    if not can_sport_host(g) then raise exception 'hosts only'; end if;
    select price into pr from sport_events where id = e and sport = g;
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
revoke all on function host_debt(text, uuid, uuid, boolean) from public, anon;
grant execute on function host_debt(text, uuid, uuid, boolean) to authenticated;

-- a blocked person cannot sign up anywhere
create or replace function signup_block_guard()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if is_blocked(new.user_id) then raise exception 'blocked: долг 1000 ฿ и больше — сначала пополни баланс'; end if;
  return new;
end $$;
drop trigger if exists signup_block_guard on signups;
create trigger signup_block_guard before insert on signups for each row execute function signup_block_guard();
drop trigger if exists signup_block_guard on sport_signups;
create trigger signup_block_guard before insert on sport_signups for each row execute function signup_block_guard();
drop trigger if exists signup_block_guard on csignups;
create trigger signup_block_guard before insert on csignups for each row execute function signup_block_guard();
