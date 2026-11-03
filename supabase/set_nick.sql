-- 03.11.2026: only @tivishka renames other dachniks inside the app
create or replace function public.set_nick(u uuid, n text) returns text
language plpgsql security definer set search_path = public as $$
declare v text := regexp_replace(trim(coalesce(n, '')), '\s+', ' ', 'g');
begin
  if not public.can_grant_premium() then raise exception 'менять ники другим может только @tivishka'; end if;
  if char_length(v) < 1 or char_length(v) > 24 then raise exception 'ник до 24 символов'; end if;
  update profiles set nick = v where id = u;
  if not found then raise exception 'дачник не найден'; end if;
  return v;
end $$;
revoke execute on function public.set_nick(uuid, text) from public, anon;
grant execute on function public.set_nick(uuid, text) to authenticated;
