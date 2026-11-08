-- Баланс Дачи: общая касса на завозы. Пополнить может любой (наличными или QR, @tivishka подтверждает), вывести — только @tivishka.
create table if not exists fund_tx (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references profiles(id),
  amount int not null check (amount <> 0 and abs(amount) <= 1000000),
  method text not null check (method in ('cash', 'qr', 'out')),
  note text,
  status text not null default 'pending' check (status in ('pending', 'confirmed', 'rejected')),
  created_at timestamptz not null default now(),
  decided_by uuid, decided_at timestamptz
);
alter table fund_tx enable row level security;
drop policy if exists fund_tx_read on fund_tx;
create policy fund_tx_read on fund_tx for select to authenticated using (true);
create table if not exists fund_settings (id int primary key default 1 check (id = 1), stored_in text, updated_at timestamptz default now());
insert into fund_settings (id, stored_in) values (1, 'Наличные баты у @tivishka') on conflict do nothing;
alter table fund_settings enable row level security;
drop policy if exists fund_settings_read on fund_settings;
create policy fund_settings_read on fund_settings for select to authenticated using (true);

create or replace function public.fund_balance() returns int language sql stable security definer set search_path to 'public' as $$
  select coalesce(sum(amount), 0)::int from fund_tx where status = 'confirmed';
$$;
create or replace function public.fund_topup(a int, m text, n text) returns uuid language plpgsql security definer set search_path to 'public' as $$
declare id_ uuid;
begin
  if auth.uid() is null then raise exception 'login'; end if;
  if a is null or a < 1 or a > 1000000 then raise exception 'bad amount'; end if;
  if m not in ('cash', 'qr') then raise exception 'bad method'; end if;
  if (select count(*) from fund_tx where user_id = auth.uid() and status = 'pending') >= 3 then raise exception 'too many pending'; end if;
  insert into fund_tx (user_id, amount, method, note) values (auth.uid(), a, m, nullif(left(trim(n), 140), '')) returning id into id_;
  -- the owner's own top-up is the cash in his hands: no need to confirm it
  if can_grant_premium() then update fund_tx set status = 'confirmed', decided_by = auth.uid(), decided_at = now() where id = id_; end if;
  return id_;
end $$;
create or replace function public.fund_withdraw(a int, n text) returns uuid language plpgsql security definer set search_path to 'public' as $$
declare id_ uuid;
begin
  if not can_grant_premium() then raise exception 'only @tivishka'; end if;
  if a is null or a < 1 or a > 1000000 then raise exception 'bad amount'; end if;
  if coalesce(trim(n), '') = '' then raise exception 'need note'; end if;
  insert into fund_tx (user_id, amount, method, note, status, decided_by, decided_at)
  values (auth.uid(), -a, 'out', left(trim(n), 140), 'confirmed', auth.uid(), now()) returning id into id_;
  return id_;
end $$;
create or replace function public.fund_decide(tx uuid, ok boolean) returns void language plpgsql security definer set search_path to 'public' as $$
begin
  if not can_grant_premium() then raise exception 'only @tivishka'; end if;
  update fund_tx set status = case when ok then 'confirmed' else 'rejected' end, decided_by = auth.uid(), decided_at = now() where id = tx and status = 'pending';
  if not found then raise exception 'not pending'; end if;
end $$;
create or replace function public.fund_cancel(tx uuid) returns void language plpgsql security definer set search_path to 'public' as $$
begin
  delete from fund_tx where id = tx and user_id = auth.uid() and status = 'pending';
end $$;
create or replace function public.fund_set_stored(t text) returns void language plpgsql security definer set search_path to 'public' as $$
begin
  if not can_grant_premium() then raise exception 'only @tivishka'; end if;
  update fund_settings set stored_in = nullif(left(trim(t), 200), ''), updated_at = now() where id = 1;
end $$;
revoke all on function public.fund_balance(), public.fund_topup(int, text, text), public.fund_withdraw(int, text), public.fund_decide(uuid, boolean), public.fund_cancel(uuid), public.fund_set_stored(text) from public, anon;
grant execute on function public.fund_balance(), public.fund_topup(int, text, text), public.fund_withdraw(int, text), public.fund_decide(uuid, boolean), public.fund_cancel(uuid), public.fund_set_stored(text) to authenticated;
do $$ begin alter publication supabase_realtime add table fund_tx; exception when others then null; end $$;
