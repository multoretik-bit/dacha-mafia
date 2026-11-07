alter table world_presence add column if not exists geo_note text, add column if not exists geo_at timestamptz;
create or replace function public.geo_note(t text) returns void language sql security definer set search_path to 'public' as $$
  update world_presence set geo_note = left(t, 120), geo_at = now() where user_id = auth.uid();
$$;
grant execute on function public.geo_note(text) to authenticated;
