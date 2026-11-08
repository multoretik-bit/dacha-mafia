-- 08.11.2026: на ход — 1 минута. Не походил — поражение:
-- шахматы/шашки — проигрыш партии; дурак — кто должен был ходить или отбиваться, тот дурак (подкидывающий просто пасует);
-- «Ривер» — встаёшь из-за стола, фишки сгорают, игра идёт дальше без тебя.

-- someone leaves «Ривер»: fold, out of the table, chips off; the last one standing takes what is on the table
create or replace function pk_leave(g uuid, u uuid, why text) returns void language plpgsql security definer set search_path = public as $$
declare r world_games; st jsonb; outp uuid[]; seats uuid[];
begin
  select * into r from world_games where id = g;
  st := r.state; outp := gm_uids(st->'out'); if not u = any(outp) then outp := outp || u; end if;
  st := st || jsonb_build_object('live', to_jsonb(array_remove(gm_uids(st->'live'), u)), 'out', to_jsonb(outp),
    'chips', jsonb_set(coalesce(st->'chips', '{}'), array[u::text], '0'::jsonb),
    'log', (select left(coalesce(nullif(nick, ''), 'Дачник'), 18) from profiles where id = u) || ' ' || why);
  update world_games set state = st where id = g;
  seats := array(select q from unnest(r.players) q where gm_int(st->'chips', q) > 0 and not q = any(outp));
  if coalesce(array_length(seats, 1), 0) <= 1 then
    if seats[1] is not null then
      update world_games set state = jsonb_set(state, array['chips', seats[1]::text], to_jsonb(gm_int(state->'chips', seats[1]) + coalesce((state->>'pot')::int, 0)
        + (select coalesce(sum(value::int), 0) from jsonb_each_text(coalesce(state->'bet', '{}'))))) where id = g;
    end if;
    perform pk_finish(g, seats[1]); return;
  end if;
  if st->>'street' <> 'result' then perform pk_advance(g, case when r.turn = u then u else null end); end if;
end $$;
revoke all on function pk_leave(uuid, uuid, text) from public, anon, authenticated;

create or replace function game_resign(g uuid) returns void language plpgsql security definer set search_path = public as $$
declare r world_games; w uuid; me_ uuid := auth.uid(); p uuid;
begin
  select * into r from world_games where id = g for update;
  if not found or not (me_ = r.a or me_ = r.b or me_ = any(r.players)) or r.status not in ('active', 'invite') then raise exception 'not your game'; end if;
  if r.status = 'invite' then
    if r.kind in ('chess', 'checkers') or me_ = r.a then update world_games set status = 'declined', updated_at = now() where id = g; return; end if;
    update world_games set lobby = lobby || jsonb_build_object(me_::text, 'declined'), ver = ver + 1, updated_at = now() where id = g;
    if not exists (select 1 from jsonb_each_text((select lobby from world_games where id = g)) where value = 'invited') then perform gm_begin(g); end if;
    return;
  end if;
  if r.kind in ('chess', 'checkers') then
    w := case when me_ = r.a then r.b else r.a end;
    update world_games set status = 'done', result = 'resign', winner = w, turn = null, ver = ver + 1, updated_at = now() where id = g;
    perform world_xp(w, 30); perform world_xp(me_, 5); return;
  end if;
  if r.kind = 'durak' then
    update world_games set status = 'done', result = 'resign', state = state || jsonb_build_object('loser', me_),
      winner = (select q from unnest(r.players) q where q <> me_ limit 1), turn = null, ver = ver + 1, updated_at = now() where id = g;
    foreach p in array r.players loop perform world_xp(p, case when p = me_ then 5 else 20 end); end loop;
    return;
  end if;
  -- «Ривер»: a guest who has not sat down yet just leaves the list
  if coalesce(r.lobby->>me_::text, 'in') = 'invited' then perform game_answer(g, false); return; end if;
  perform pk_leave(g, me_, 'ушёл из-за стола');
end $$;

create or replace function game_timeout(g uuid) returns boolean language plpgsql security definer set search_path = public as $$
declare r world_games; w uuid; st jsonb; t uuid; p uuid;
begin
  select * into r from world_games where id = g for update;
  if not found or not (auth.uid() = r.a or auth.uid() = r.b or auth.uid() = any(r.players)) or r.status <> 'active' then return false; end if;
  if r.kind = 'poker' and r.state->>'street' = 'result' then
    if r.updated_at > now() - interval '4 seconds' then return false; end if;
    perform pk_deal(g); return true;
  end if;
  if r.turn is null or r.updated_at > now() - interval '1 minute' then return false; end if;
  t := r.turn; st := r.state;
  if r.kind in ('chess', 'checkers') then
    w := case when t = r.a then r.b else r.a end;
    update world_games set status = 'done', result = 'timeout', winner = w, turn = null, ver = ver + 1, updated_at = now() where id = g;
    perform world_xp(w, 30); perform world_xp(case when w = r.a then r.b else r.a end, 5);
  elsif r.kind = 'durak' then
    if t = (st->>'def')::uuid or jsonb_array_length(st->'table') = 0 then
      update world_games set status = 'done', result = 'timeout', state = state || jsonb_build_object('loser', t),
        winner = (select q from unnest(r.players) q where q <> t limit 1), turn = null, ver = ver + 1, updated_at = now() where id = g;
      foreach p in array r.players loop perform world_xp(p, case when p = t then 5 else 20 end); end loop;
    else
      -- a thrower does not have to throw: a minute of silence is a pass
      update world_games set state = state || jsonb_build_object('passed', coalesce(state->'passed', '[]'::jsonb) || to_jsonb(t::text)) where id = g;
      perform dk_settle(g);
    end if;
  else
    perform pk_leave(g, t, 'не походил за минуту — выбыл');
  end if;
  return true;
end $$;
