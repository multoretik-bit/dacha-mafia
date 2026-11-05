-- DACHA 06.11: profile themes v2. Everybody: scene backgrounds for the cover.
-- PREMIUM only: full dark profile (dark), a text on the cover (title), an own cover photo (img).
-- Without an active PREMIUM those keys are dropped on save.

create or replace function public.is_premium_now(u uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select premium_until > now() from profiles where id = u), false)
$$;
revoke all on function public.is_premium_now(uuid) from public, anon;
grant execute on function public.is_premium_now(uuid) to authenticated;

create or replace function set_theme(t jsonb)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'login'; end if;
  if t is not null and (jsonb_typeof(t) <> 'object' or pg_column_size(t) > 4000) then raise exception 'bad theme'; end if;
  if t ? 'stickers' and jsonb_array_length(t->'stickers') > 8 then raise exception 'too many stickers'; end if;
  if t is not null and not is_premium_now(auth.uid()) then t := t - 'dark' - 'title' - 'img'; end if;
  if t ? 'title' and length(t->>'title') > 40 then raise exception 'title too long'; end if;
  if t ? 'img' and t->>'img' is not null
     and t->>'img' not like 'https://uiaxlwlllrbulirhtdlo.supabase.co/storage/v1/object/public/covers/' || auth.uid()::text || '/%' then
    raise exception 'bad image';
  end if;
  update profiles set theme = t where id = auth.uid();
end $$;
revoke all on function set_theme(jsonb) from public, anon;
grant execute on function set_theme(jsonb) to authenticated;

-- own cover photos: public bucket, everyone writes only into his own folder and only with PREMIUM
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('covers', 'covers', true, 6291456, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update set public = true, file_size_limit = 6291456;
drop policy if exists "premium uploads own cover" on storage.objects;
create policy "premium uploads own cover" on storage.objects for insert to authenticated
  with check (bucket_id = 'covers' and (storage.foldername(name))[1] = auth.uid()::text and public.is_premium_now(auth.uid()));
