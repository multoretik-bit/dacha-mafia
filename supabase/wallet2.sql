-- DACHA 05.11 (2): transfers between people, PREMIUM bonus +200 ฿ a month, PREMIUM icon

alter table wallet_tx add column if not exists peer_id uuid references profiles(id) on delete set null;

-- send baht to anybody (only what you have)
create or replace function wallet_transfer(to_ uuid, amount int, note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare me_ uuid := auth.uid(); bal int; fn text; tn text;
begin
  if me_ is null then raise exception 'login'; end if;
  if to_ is null or to_ = me_ then raise exception 'bad recipient'; end if;
  if amount is null or amount < 1 or amount > 100000 then raise exception 'bad amount'; end if;
  if not exists (select 1 from profiles where id = to_ and tg_id is not null) then raise exception 'no such person'; end if;
  perform pg_advisory_xact_lock(hashtext(me_::text));
  bal := (wallet(me_)->>'balance')::int;
  if bal < amount then raise exception 'not enough balance'; end if;
  select nick into fn from profiles where id = me_;
  select nick into tn from profiles where id = to_;
  insert into wallet_tx (user_id, amount, method, status, peer_id, note, created_by, decided_by, decided_at)
  values (me_, -amount, 'transfer', 'confirmed', to_, coalesce(nullif(trim(note), ''), 'Перевод → ' || tn), me_, me_, now()),
         (to_, amount, 'transfer', 'confirmed', me_, coalesce(nullif(trim(note), ''), 'Перевод от ' || fn), me_, me_, now());
end $$;
revoke all on function wallet_transfer(uuid, int, text) from public, anon;
grant execute on function wallet_transfer(uuid, int, text) to authenticated;

-- every PREMIUM month also brings +200 ฿ to the balance
create or replace function premium_extend(u uuid) returns void language plpgsql security definer set search_path = public as $$
begin
  update profiles set premium_until = case
      when premium_until = 'infinity' then premium_until
      else greatest(coalesce(premium_until, now()), now()) + interval '1 month' end
  where id = u;
  insert into wallet_tx (user_id, amount, method, status, note, created_by, decided_by, decided_at)
  values (u, 200, 'adjust', 'confirmed', 'Бонус PREMIUM', auth.uid(), auth.uid(), now());
end $$;
revoke all on function premium_extend(uuid) from public, anon, authenticated;

-- PREMIUM icon on the avatar
alter table profiles add column if not exists prem_icon text check (prem_icon is null or char_length(prem_icon) <= 16);
create or replace function set_prem_icon(i text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from profiles where id = auth.uid() and premium_until > now()) then raise exception 'premium only'; end if;
  update profiles set prem_icon = nullif(trim(i), '') where id = auth.uid();
end $$;
revoke all on function set_prem_icon(text) from public, anon;
grant execute on function set_prem_icon(text) to authenticated;

-- bot tells a person when money comes in (function tg, action wallet_notify, once per row)
alter table wallet_tx add column if not exists notified_at timestamptz;

-- return the recipient's row id so the client can ask the bot to notify
drop function if exists wallet_transfer(uuid, int, text);
create or replace function wallet_transfer(to_ uuid, amount int, note text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare me_ uuid := auth.uid(); bal int; fn text; tn text; rid uuid;
begin
  if me_ is null then raise exception 'login'; end if;
  if to_ is null or to_ = me_ then raise exception 'bad recipient'; end if;
  if amount is null or amount < 1 or amount > 100000 then raise exception 'bad amount'; end if;
  if not exists (select 1 from profiles where id = to_ and tg_id is not null) then raise exception 'no such person'; end if;
  perform pg_advisory_xact_lock(hashtext(me_::text));
  bal := (wallet(me_)->>'balance')::int;
  if bal < amount then raise exception 'not enough balance'; end if;
  select nick into fn from profiles where id = me_;
  select nick into tn from profiles where id = to_;
  insert into wallet_tx (user_id, amount, method, status, peer_id, note, created_by, decided_by, decided_at)
  values (me_, -amount, 'transfer', 'confirmed', to_, coalesce(nullif(trim(note), ''), 'Перевод → ' || tn), me_, me_, now());
  insert into wallet_tx (user_id, amount, method, status, peer_id, note, created_by, decided_by, decided_at)
  values (to_, amount, 'transfer', 'confirmed', me_, coalesce(nullif(trim(note), ''), 'Перевод от ' || fn), me_, me_, now()) returning id into rid;
  return rid;
end $$;
revoke all on function wallet_transfer(uuid, int, text) from public, anon;
grant execute on function wallet_transfer(uuid, int, text) to authenticated;

drop function if exists pay_receive(uuid, int, text, uuid, text);
create or replace function pay_receive(u uuid, amount int, m text default 'cash', e uuid default null, g text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare rid uuid;
begin
  if not is_any_host() then raise exception 'hosts only'; end if;
  if m not in ('qr', 'cash') or amount is null or amount < 1 or amount > 100000 then raise exception 'bad payment'; end if;
  insert into wallet_tx (user_id, amount, method, game, event_id, status, created_by, decided_by, decided_at)
  values (u, amount, m, g, e, 'confirmed', auth.uid(), auth.uid(), now()) returning id into rid;
  return rid;
end $$;
grant execute on function pay_receive(uuid, int, text, uuid, text) to authenticated;
