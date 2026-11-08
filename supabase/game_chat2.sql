-- 08.11.2026: общий чат стола. Одно сообщение = строка каждому, кто за столом (grp связывает копии):
-- так у каждого свой «прочитано», бот дублирует непрочитанное в Telegram, а ответ из Telegram уходит всем.
alter table dm_messages add column if not exists grp uuid;
create index if not exists dm_grp on dm_messages (grp) where grp is not null;

-- everybody at the table except u (in a lobby — without those who declined)
create or replace function gm_others(g uuid, u uuid) returns uuid[] language sql stable security definer set search_path = public as $$
  select coalesce(array(select distinct x from world_games w,
      unnest(case when coalesce(array_length(w.players, 1), 0) > 0 then w.players else array[w.a, w.b] end) x
    where w.id = g and x is not null and x <> u and coalesce(w.lobby->>x::text, '') <> 'declined'), '{}')
$$;
revoke all on function gm_others(uuid, uuid) from public, anon, authenticated;

create or replace function game_say(g uuid, body_ text) returns uuid language plpgsql security definer set search_path = public as $$
declare t text := left(trim(body_), 500); grp_ uuid := gen_random_uuid(); to_ uuid[];
begin
  if t = '' then raise exception 'empty'; end if;
  if not exists (select 1 from world_games where id = g and (a = auth.uid() or b = auth.uid() or auth.uid() = any(players))) then raise exception 'not your game'; end if;
  if (select count(distinct coalesce(grp, id)) from dm_messages where from_id = auth.uid() and created_at > now() - interval '1 minute') >= 30 then raise exception 'too fast'; end if;
  to_ := gm_others(g, auth.uid());
  if coalesce(array_length(to_, 1), 0) = 0 then raise exception 'nobody here'; end if;
  insert into dm_messages (from_id, to_id, body, game_id, grp) select auth.uid(), x, t, g, grp_ from unnest(to_) x;
  return grp_;
end $$;
revoke all on function game_say(uuid, text) from public, anon;
grant execute on function game_say(uuid, text) to authenticated;
