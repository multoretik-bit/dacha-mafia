-- DACHA 06.11: a rejected money request (top-up / PREMIUM / withdrawal) is deleted for good,
-- and its author can't send a new one for 24 hours. Top-up requests are capped at 20 000 ฿.
-- Reason: @Ruslan_SHDL kept re-sending "+99 999 ฿" top-ups right after each rejection.

create table if not exists request_cooldown (
  user_id uuid primary key references profiles(id) on delete cascade,
  until timestamptz not null
);
alter table request_cooldown enable row level security;   -- no policies: only definer functions touch it

create or replace function req_reject(tx uuid)
returns void language plpgsql security definer set search_path = public as $$
declare r wallet_tx;
begin
  if not can_grant_premium() then raise exception 'only tivishka'; end if;
  select * into r from wallet_tx where id = tx and status = 'pending' and event_id is null and purpose in ('topup', 'premium', 'withdraw');
  if not found then return; end if;
  delete from wallet_tx where id = tx;
  insert into request_cooldown (user_id, until) values (r.user_id, now() + interval '24 hours')
  on conflict (user_id) do update set until = excluded.until;
end $$;
revoke all on function req_reject(uuid) from public, anon;
grant execute on function req_reject(uuid) to authenticated;

create or replace function guard_money_request() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'pending' and new.event_id is null and new.purpose in ('topup', 'premium', 'withdraw') then
    if exists (select 1 from request_cooldown where user_id = new.user_id and until > now()) then raise exception 'request cooldown'; end if;
    if new.purpose = 'topup' and new.amount > 20000 then raise exception 'too big'; end if;
  end if;
  return new;
end $$;
drop trigger if exists money_request_guard on wallet_tx;
create trigger money_request_guard before insert or update of amount, status on wallet_tx for each row execute function guard_money_request();
