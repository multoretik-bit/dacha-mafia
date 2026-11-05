-- DACHA 05.11: birthdays from Telegram (getChat birthdate) or set by the person; only day + month are shown
alter table profiles add column if not exists birth_day int check (birth_day between 1 and 31);
alter table profiles add column if not exists birth_month int check (birth_month between 1 and 12);
alter table profiles add column if not exists birth_year int check (birth_year between 1900 and 2100);
alter table profiles add column if not exists birth_src text check (birth_src in ('tg', 'manual'));

create or replace function set_birthday(d int, m int)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'login'; end if;
  if d is null or m is null then update profiles set birth_day = null, birth_month = null, birth_year = null, birth_src = null where id = auth.uid(); return; end if;
  if m < 1 or m > 12 or d < 1 or d > 31 then raise exception 'bad date'; end if;
  update profiles set birth_day = d, birth_month = m, birth_src = 'manual' where id = auth.uid();
end $$;
revoke all on function set_birthday(int, int) from public, anon;
grant execute on function set_birthday(int, int) to authenticated;
