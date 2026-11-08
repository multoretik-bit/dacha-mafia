-- 08.11.2026: «Ривер» начинается, как только за столом двое; кто примет приглашение позже — садится со следующей раздачи со своим стеком.
-- Хозяин может звать новых людей и во время игры.

-- start: durak — only those who said yes; «Ривер» — those who said yes play, the invited stay on the list and may sit later
create or replace function gm_begin(g uuid) returns void language plpgsql security definer set search_path = public as $$
declare r world_games; ps uuid[]; keep uuid[];
begin
  select * into r from world_games where id = g;
  ps := array(select p from unnest(r.players) with ordinality t(p, i) where r.lobby->>p::text = 'in' order by i);
  if coalesce(array_length(ps, 1), 0) < 2 then
    update world_games set status = 'declined', turn = null, updated_at = now() where id = g; return;
  end if;
  keep := case when r.kind = 'poker' then array(select p from unnest(r.players) with ordinality t(p, i) where coalesce(r.lobby->>p::text, '') in ('in', 'invited') order by i) else ps end;
  update world_games set players = keep, status = 'active', b = case when array_length(keep, 1) = 2 then keep[2] else null end, updated_at = now() where id = g;
  if r.kind = 'durak' then perform durak_deal(g); else perform pk_start(g); end if;
end $$;
revoke all on function gm_begin(uuid) from public, anon, authenticated;

create or replace function game_answer(g uuid, ok boolean) returns void language plpgsql security definer set search_path = public as $$
declare r world_games; me_ uuid := auth.uid();
begin
  select * into r from world_games where id = g for update;
  if not found then raise exception 'not your invite'; end if;
  if r.kind in ('chess', 'checkers') then
    if r.status <> 'invite' or r.b <> me_ then raise exception 'not your invite'; end if;
    update world_games set status = case when ok then 'active' else 'declined' end, turn = case when ok then r.a else null end, updated_at = now() where id = g;
    return;
  end if;
  if coalesce(r.lobby->>me_::text, '') <> 'invited' then raise exception 'not your invite'; end if;
  if r.status = 'active' then
    -- «Ривер» is already on: sit down from the next hand with a full stack
    if r.kind <> 'poker' then raise exception 'already started'; end if;
    if ok then
      update world_games set lobby = lobby || jsonb_build_object(me_::text, 'in'),
        state = jsonb_set(state, array['chips', me_::text], to_jsonb(coalesce((state->>'stack')::int, 500)))
          || jsonb_build_object('log', (select left(coalesce(nullif(nick, ''), 'Дачник'), 18) from profiles where id = me_) || ' садится за стол — со следующей раздачи'),
        ver = ver + 1, updated_at = case when state->>'street' = 'result' then updated_at else now() end where id = g;
    else
      update world_games set lobby = lobby || jsonb_build_object(me_::text, 'declined'), players = array_remove(players, me_), ver = ver + 1 where id = g;
    end if;
    return;
  end if;
  if r.status <> 'invite' then raise exception 'not your invite'; end if;
  update world_games set lobby = lobby || jsonb_build_object(me_::text, case when ok then 'in' else 'declined' end), ver = ver + 1, updated_at = now() where id = g;
  select * into r from world_games where id = g;
  -- «Ривер»: two at the table — we start; durak: when everybody answered (or the host presses «начать»)
  if (r.kind = 'poker' and (select count(*) from jsonb_each_text(r.lobby) where value = 'in') >= 2)
     or not exists (select 1 from jsonb_each_text(r.lobby) where value = 'invited') then perform gm_begin(g); end if;
end $$;

-- chips only for those who sat down
create or replace function pk_start(g uuid) returns void language plpgsql security definer set search_path = public as $$
declare r world_games; ch jsonb := '{}'; p uuid; stack int;
begin
  select * into r from world_games where id = g;
  stack := coalesce((r.opts->>'stack')::int, 500);
  foreach p in array r.players loop if r.lobby->>p::text = 'in' or r.lobby = '{}'::jsonb then ch := ch || jsonb_build_object(p::text, stack); end if; end loop;
  update world_games set state = jsonb_build_object('chips', ch, 'hand', 0, 'out', '[]'::jsonb, 'stack', stack, 'base', greatest(1, stack / 100)) where id = g;
  perform pk_deal(g);
end $$;
revoke all on function pk_start(uuid) from public, anon, authenticated;

-- XP only for those who played
create or replace function pk_finish(g uuid, w uuid) returns void language plpgsql security definer set search_path = public as $$
declare r world_games; p uuid;
begin
  select * into r from world_games where id = g;
  update world_games set status = 'done', result = case when w is null then 'draw' else 'win' end, winner = w, turn = null, ver = ver + 1, updated_at = now() where id = g;
  foreach p in array r.players loop
    if r.state->'chips' ? p::text then perform world_xp(p, case when p = w then 30 else 10 end); end if;
  end loop;
end $$;
revoke all on function pk_finish(uuid, uuid) from public, anon, authenticated;

-- call more friends: into a lobby, and into a «Ривер» that is already on
create or replace function game_add(g uuid, opps uuid[]) returns void language plpgsql security definer set search_path = public as $$
declare r world_games; u uuid; lb jsonb; ps uuid[];
begin
  select * into r from world_games where id = g for update;
  if not found or r.a <> auth.uid() or r.kind not in ('durak', 'poker') or not (r.status = 'invite' or (r.status = 'active' and r.kind = 'poker')) then raise exception 'not your game'; end if;
  lb := r.lobby; ps := r.players;
  foreach u in array coalesce(opps, '{}') loop
    if u is null or (u = any(ps) and coalesce(lb->>u::text, '') <> 'declined') or not exists (select 1 from profiles where id = u and tg_id is not null) then continue; end if;
    if not u = any(ps) then ps := ps || u; end if;
    lb := lb || jsonb_build_object(u::text, 'invited');
  end loop;
  if array_length(ps, 1) > 8 then raise exception 'too many players'; end if;
  update world_games set players = ps, lobby = lb, ver = ver + 1 where id = g;
end $$;
