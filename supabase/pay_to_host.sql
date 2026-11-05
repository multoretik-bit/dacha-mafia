-- DACHA 05.11: paying a game from the app balance sends the money to the host of that date.
-- Allowed only once a host has signed up for the date ("я веду"). The evpay row keeps peer_id = host;
-- when the date starts (the player's computed charge appears) the host's balance grows by that amount.

create or replace function date_host(g text, e uuid)
returns uuid language sql stable security definer set search_path = public as $$
  select case when g = 'mafia'
    then (select user_id from signups where event_id = e and role = 'host' order by created_at limit 1)
    else (select user_id from sport_signups where event_id = e and role = 'host' order by created_at limit 1) end;
$$;
grant execute on function date_host(text, uuid) to authenticated;

create or replace function pay_from_balance(e uuid, g text)
returns uuid language plpgsql security definer set search_path = public as $$
declare me_ uuid := auth.uid(); pr int; av int; rid uuid; h uuid;
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
  if exists (select 1 from wallet_tx where user_id = me_ and event_id = e and status = 'confirmed' and purpose in ('topup', 'evpay')) then raise exception 'already paid'; end if;
  perform pg_advisory_xact_lock(hashtext(me_::text));
  av := (wallet(me_)->>'available')::int;
  if av < pr then raise exception 'not enough balance'; end if;
  insert into wallet_tx (user_id, amount, method, game, event_id, status, purpose, peer_id, note, created_by, decided_by, decided_at)
  values (me_, pr, 'balance', g, e, 'confirmed', 'evpay', h, 'Оплата с баланса ведущему', me_, me_, now()) returning id into rid;
  return rid;
end $$;

-- money a host has received for dates that already started (payer was charged)
create or replace function wallet_earned(u uuid)
returns table(amount int, payer uuid, game text, event_id uuid, at timestamptz)
language sql stable security definer set search_path = public as $$
  select t.amount, t.user_id, t.game, t.event_id, t.created_at from wallet_tx t
  where t.purpose = 'evpay' and t.status = 'confirmed' and t.peer_id = u
    and exists (select 1 from wallet_charges_all() c where c.user_id = t.user_id and c.event_id = t.event_id);
$$;
revoke all on function wallet_earned(uuid) from public, anon, authenticated;

create or replace function wallet(u uuid default auth.uid())
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare ch jsonb; tx jsonb; inc jsonb; paid int; owed int; pend int; res int; wd int; earn int;
begin
  if u is null or (u <> auth.uid() and not is_any_host()) then raise exception 'not allowed'; end if;
  select coalesce(jsonb_agg(to_jsonb(c) order by c.day desc, c.start_time desc), '[]'), coalesce(sum(c.price), 0)
    into ch, owed from wallet_charges_all() c where c.user_id = u;
  select coalesce(jsonb_agg(to_jsonb(t) - 'user_id' order by t.created_at desc), '[]') into tx
    from (select * from wallet_tx where user_id = u order by created_at desc limit 200) t;
  select coalesce(jsonb_agg(jsonb_build_object('amount', w.amount, 'payer', w.payer, 'nick', p.nick, 'game', w.game, 'event_id', w.event_id, 'at', w.at) order by w.at desc), '[]'),
         coalesce(sum(w.amount), 0)
    into inc, earn from wallet_earned(u) w left join profiles p on p.id = w.payer;
  select coalesce(sum(amount) filter (where status = 'confirmed' and purpose in ('topup', 'withdraw')), 0),
         coalesce(sum(amount) filter (where status = 'pending' and purpose = 'topup'), 0),
         coalesce(-sum(amount) filter (where status = 'pending' and purpose = 'withdraw'), 0)
    into paid, pend, wd from wallet_tx where user_id = u;
  res := wallet_reserved(u);
  return jsonb_build_object('balance', paid - owed + earn, 'reserved', res, 'withdrawing', wd, 'available', paid - owed + earn - res - wd,
    'pending', pend, 'paid', paid, 'owed', owed, 'earned', earn, 'income', inc, 'charges', ch, 'txs', tx);
end $$;

create or replace function wallet_balances()
returns table(user_id uuid, balance bigint, pending bigint)
language sql stable security definer set search_path = public as $$
  with c as (select user_id, sum(price) s from wallet_charges_all() group by 1),
       t as (select user_id, sum(amount) filter (where status = 'confirmed' and purpose in ('topup', 'withdraw')) ok,
                    sum(amount) filter (where status = 'pending' and purpose = 'topup') pe from wallet_tx group by 1),
       h as (select t2.peer_id user_id, sum(t2.amount) s from wallet_tx t2
             where t2.purpose = 'evpay' and t2.status = 'confirmed' and t2.peer_id is not null
               and exists (select 1 from wallet_charges_all() c2 where c2.user_id = t2.user_id and c2.event_id = t2.event_id) group by 1)
  select pr.id, coalesce(t.ok, 0) - coalesce(c.s, 0) + coalesce(h.s, 0), coalesce(t.pe, 0)
  from profiles pr left join c on c.user_id = pr.id left join t on t.user_id = pr.id left join h on h.user_id = pr.id
  where is_any_host() and pr.tg_id is not null and (c.user_id is not null or t.user_id is not null or h.user_id is not null);
$$;
