-- DACHA 06.11: top-up in baht, rubles or USDT (TRC20). The balance is always in baht;
-- the request remembers what the person says he paid ("Оплатил 3 250 ₽ по скану", "Оплатил 31.5 USDT").
create or replace function topup_request(amount int, cur text, paid numeric, m text default 'qr')
returns uuid language plpgsql security definer set search_path = public as $$
declare id_ uuid; n text;
begin
  if auth.uid() is null then raise exception 'login'; end if;
  if cur not in ('THB', 'RUB', 'USD') then raise exception 'bad currency'; end if;
  if m not in ('qr', 'cash') then raise exception 'bad method'; end if;
  if amount is null or amount < 1 or amount > 20000 then raise exception 'too big'; end if;
  if cur <> 'THB' and (paid is null or paid <= 0 or paid > 10000000) then raise exception 'bad amount'; end if;
  n := case cur
    when 'RUB' then 'Оплатил ' || replace(trim(to_char(ceil(paid), 'FM9G999G999')), ',', ' ') || ' ₽ по скану'
    when 'USD' then 'Оплатил ' || trim(to_char(paid, 'FM9999990.00')) || ' USDT (TRC20)'
    else null end;
  select id into id_ from wallet_tx where user_id = auth.uid() and status = 'pending' and purpose = 'topup' and event_id is null limit 1;
  if id_ is not null then
    update wallet_tx set amount = topup_request.amount, method = m, currency = cur, note = n, created_at = now() where id = id_;
  else
    insert into wallet_tx (user_id, amount, method, currency, purpose, note, created_by)
    values (auth.uid(), amount, m, cur, 'topup', n, auth.uid()) returning id into id_;
  end if;
  return id_;
end $$;
revoke all on function topup_request(int, text, numeric, text) from public, anon;
grant execute on function topup_request(int, text, numeric, text) to authenticated;
