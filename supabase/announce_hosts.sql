-- DACHA 05.11: every host may upload an announcement picture (tg function checks the game he hosts)
drop policy if exists "any host uploads announce" on storage.objects;
create policy "any host uploads announce" on storage.objects for insert to authenticated
  with check (bucket_id = 'announce' and public.is_any_host());
