-- DACHA 05.11: up to two QR per person, each with its own caption ("за игру", "на чай"…)
alter table profiles add column if not exists pay_qr_label text check (pay_qr_label is null or char_length(pay_qr_label) <= 40);
alter table profiles add column if not exists pay_qr2 text check (pay_qr2 is null or pay_qr2 ~* '^https://');
alter table profiles add column if not exists pay_qr2_label text check (pay_qr2_label is null or char_length(pay_qr2_label) <= 40);

create or replace function set_pay_qr_slot(slot int, url text, label text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_any_host() then raise exception 'hosts only'; end if;
  if url is not null and url !~* '^https://' then raise exception 'bad url'; end if;
  if slot = 1 then update profiles set pay_qr = nullif(url, ''), pay_qr_label = nullif(trim(label), '') where id = auth.uid();
  elsif slot = 2 then update profiles set pay_qr2 = nullif(url, ''), pay_qr2_label = nullif(trim(label), '') where id = auth.uid();
  else raise exception 'bad slot'; end if;
end $$;
revoke all on function set_pay_qr_slot(int, text, text) from public, anon;
grant execute on function set_pay_qr_slot(int, text, text) to authenticated;
