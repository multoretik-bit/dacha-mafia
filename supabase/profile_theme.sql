-- DACHA 05.11: everyone decorates his own profile page (cover, accent colour, emoji stickers, hidden blocks)
alter table profiles add column if not exists theme jsonb;
create or replace function set_theme(t jsonb)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'login'; end if;
  if t is not null and (jsonb_typeof(t) <> 'object' or pg_column_size(t) > 4000) then raise exception 'bad theme'; end if;
  if t ? 'stickers' and jsonb_array_length(t->'stickers') > 8 then raise exception 'too many stickers'; end if;
  update profiles set theme = t where id = auth.uid();
end $$;
revoke all on function set_theme(jsonb) from public, anon;
grant execute on function set_theme(jsonb) to authenticated;
