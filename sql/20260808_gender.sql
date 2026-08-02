-- 성별을 명단 정보로 함께 갖는다.
--
-- 방을 배정하고 옮길 때 남녀를 섞으면 안 되는데, 지금은 시트의 성별 열을 읽지
-- 않고 버려서 운영자가 이름만 보고 짐작해야 했다. 방 인원을 현장에서 옮길 수
-- 있게 되면서 더 필요해졌다.
--
-- 편과 무관한 사람 정보라 숙박일(night1 · night2)처럼 bus_passengers 에 두고,
-- 전화번호 기준으로 그 사람의 모든 행에 함께 쓴다.
-- 값은 시트에 적힌 대로 둔다('남' · '여' · 'M' · 'F' 등). 화면에서 남/여로
-- 보여 줄 때만 첫 글자로 가른다.

alter table public.bus_passengers
  add column if not exists gender text;

-- ---------------------------------------------------------------- 방 조회
-- 방 인원에 성별을 얹는다. 방을 옮길 때 남녀가 섞이는지 바로 보이게.
create or replace function public.bus_room_members(p_rkey text)
returns jsonb
language sql
stable
set search_path to 'public'
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'name',      m.name,
           'phone',     case when public.bus_real_phone(m.phone) then m.phone else '' end,
           'no_phone',  not public.bus_real_phone(m.phone),
           'is_leader', m.is_leader,
           'gender',    coalesce(m.gender, ''),
           'night1',    m.night1,
           'night2',    m.night2)
           order by m.is_leader desc, m.name), '[]'::jsonb)
    from (
      select s.phone,
             bool_or(s.is_leader) as is_leader,
             max(p.name)          as name,
             max(p.gender)        as gender,
             bool_or(p.night1)    as night1,
             bool_or(p.night2)    as night2
        from public.bus_room_slots s
        join public.bus_passengers p on p.phone = s.phone
       where public.bus_room_key(s.room_label, s.room_no) = p_rkey
       group by s.phone
    ) m
$$;

revoke execute on function public.bus_room_members(text) from anon, authenticated;

-- ---------------------------------------------------------------- 운영자(명단)
-- 업로드 두 경로에서 성별을 함께 쓰고, 내려받기와 목록에도 싣는다.
create or replace function public.bus_admin(p_code text, p_action text, p_payload jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_code  text;
  v_leg   text;
  v_row   jsonb;
  v_rm    jsonb;
  v_rows  jsonb;
  v_tot   jsonb;
  v_req   public.bus_requests%rowtype;
  v_phone text;
  v_old   text;
  v_legs  text[];
  v_one   text;
begin
  select value into v_code from public.bus_config where key = 'admin_code';
  if v_code is null or p_code is null or p_code <> v_code then
    return jsonb_build_object('status', 'denied');
  end if;

  v_leg := coalesce(p_payload->>'leg',
                    (select value from public.bus_config where key = 'active_leg'), 'out');
  if v_leg not in ('out','back') then v_leg := 'out'; end if;

  if p_action = 'list' then
    select coalesce(jsonb_agg(t order by t.boarded, t.name), '[]'::jsonb)
      into v_rows
      from (
        select id, name,
               case when public.bus_real_phone(phone) then phone else '' end as phone,
               not public.bus_real_phone(phone) as no_phone,
               note, gender,
               to_char(boarded_at at time zone 'Asia/Seoul', 'HH24:MI') as at,
               (boarded_at is not null) as boarded
          from public.bus_passengers where leg = v_leg
      ) t;

    select jsonb_object_agg(leg, jsonb_build_object('all', c_all, 'done', c_done))
      into v_tot
      from (
        select leg, count(*) as c_all, count(boarded_at) as c_done
          from public.bus_passengers where leg in ('out','back') group by leg
      ) s;

    return jsonb_build_object(
      'status', 'ok',
      'leg', v_leg,
      'rows', v_rows,
      'totals', coalesce(v_tot, '{}'::jsonb),
      'nights', jsonb_build_object(
        'n1',     (select count(distinct phone) from public.bus_passengers where night1),
        'n2',     (select count(distinct phone) from public.bus_passengers where night2),
        'people', (select count(distinct phone) from public.bus_passengers),
        'stay',   (select count(*) from public.bus_passengers where leg = 'stay')),
      'pending', (select count(*) from public.bus_requests where status = 'pending')
                 + (select count(distinct phone) from public.bus_passengers
                     where not public.bus_real_phone(phone)),
      'open', public.bus_leg_open(v_leg),
      'collecting', jsonb_build_object('out',  public.bus_leg_open('out'),
                                       'back', public.bus_leg_open('back')),
      'active_leg', coalesce((select value from public.bus_config where key = 'active_leg'), 'out'),
      'title', coalesce((select value from public.bus_config where key = 'event_title'), '')
    );

  elsif p_action = 'sheet' then
    -- 사람 × 방 한 줄. 방이 둘이면 두 줄로 나오고, 그대로 다시 올리면
    -- 방 두 개짜리 사람으로 되돌아온다.
    select coalesce(jsonb_agg(to_jsonb(t) order by t.note nulls last, t.name, t.room_label), '[]'::jsonb)
      into v_rows
      from (
        select q.phone, q.name, q.note, q.gender, q.night1, q.night2,
               q.rides_out, q.rides_back, q.no_phone,
               s.room_label, s.room_no, coalesce(s.is_leader, false) as is_leader
          from (
            select p.phone,
                   max(p.name)            as name,
                   max(p.note)            as note,
                   max(p.gender)          as gender,
                   bool_or(p.night1)      as night1,
                   bool_or(p.night2)      as night2,
                   bool_or(p.leg = 'out') as rides_out,
                   bool_or(p.leg = 'back')as rides_back,
                   not public.bus_real_phone(max(p.phone)) as no_phone
              from public.bus_passengers p
             group by p.phone
          ) q
          left join public.bus_room_slots s on s.phone = q.phone
      ) t;
    return jsonb_build_object('status', 'ok', 'rows', v_rows,
                              'title', coalesce((select value from public.bus_config where key = 'event_title'), ''));

  elsif p_action = 'requests' then
    select coalesce(jsonb_agg(t order by t.id), '[]'::jsonb)
      into v_rows
      from (
        select id, name, phone, note, leg, kind, old_phone,
               to_char(created_at at time zone 'Asia/Seoul', 'MM-DD HH24:MI') as at
          from public.bus_requests where status = 'pending'
      ) t;
    return jsonb_build_object(
      'status', 'ok',
      'rows', v_rows,
      -- 연락처를 아직 못 받은 사람. 운영자 화면에 요청처럼 띄운다.
      'no_phone', (select coalesce(jsonb_agg(t order by t.note nulls last, t.name), '[]'::jsonb)
                     from (select distinct on (phone) phone as key, name, note
                             from public.bus_passengers
                            where not public.bus_real_phone(phone)
                            order by phone, name) t));

  elsif p_action = 'set_phone' then
    -- 자리표 번호를 진짜 번호로 바꾼다. 명단의 모든 편과 방 배정에 함께 반영.
    v_old   := coalesce(p_payload->>'key', '');
    v_phone := public.bus_norm_phone(p_payload->>'phone');
    if length(v_phone) < 10 then
      return jsonb_build_object('status', 'invalid');
    end if;
    if not exists (select 1 from public.bus_passengers where phone = v_old) then
      return jsonb_build_object('status', 'gone');
    end if;
    if exists (select 1 from public.bus_passengers where phone = v_phone) then
      return jsonb_build_object('status', 'exists');
    end if;
    update public.bus_passengers set phone = v_phone where phone = v_old;
    update public.bus_room_slots  set phone = v_phone where phone = v_old;
    return jsonb_build_object('status', 'ok');

  elsif p_action = 'request_approve' then
    select * into v_req from public.bus_requests where id = (p_payload->>'id')::bigint;
    if not found then return jsonb_build_object('status', 'gone'); end if;

    -- 번호 없이 명단에 올라가 있던 사람(이름·소속이 같음)이면 새로 넣는 대신
    -- 그 사람의 번호를 채워 준다. 편이 달라도 마찬가지다 — 숙박만 하던 사람이
    -- 버스도 타겠다고 보내오는 경우가 있다.
    v_old := public.bus_missing_phone(v_req.note, v_req.name);
    if not exists (select 1 from public.bus_passengers where phone = v_old) then
      v_old := null;
    end if;

    if v_old is not null then
      delete from public.bus_passengers
       where phone = v_req.phone
         and leg in (select leg from public.bus_passengers where phone = v_old);
      update public.bus_passengers
         set phone = v_req.phone, name = v_req.name
       where phone = v_old;
      update public.bus_room_slots set phone = v_req.phone where phone = v_old;

      insert into public.bus_passengers(name, phone, note, leg)
      values (v_req.name, v_req.phone, v_req.note, v_req.leg)
      on conflict (leg, phone) do update set name = excluded.name;

    elsif v_req.kind = 'fix' and v_req.target_id is not null
       and exists (select 1 from public.bus_passengers where id = v_req.target_id) then
      select phone into v_old from public.bus_passengers where id = v_req.target_id;

      if not public.bus_real_phone(v_old) then
        -- 번호가 없던 사람 — 모든 편과 방 배정에 함께 넣는다.
        delete from public.bus_passengers
         where phone = v_req.phone
           and leg in (select leg from public.bus_passengers where phone = v_old);
        update public.bus_passengers
           set phone = v_req.phone, name = v_req.name, note = coalesce(v_req.note, note)
         where phone = v_old;
        update public.bus_room_slots set phone = v_req.phone where phone = v_old;
      else
        delete from public.bus_passengers
         where leg = v_req.leg and phone = v_req.phone and id <> v_req.target_id;
        update public.bus_passengers
           set phone = v_req.phone, name = v_req.name, note = coalesce(v_req.note, note)
         where id = v_req.target_id;
      end if;
    else
      insert into public.bus_passengers(name, phone, note, leg)
      values (v_req.name, v_req.phone, v_req.note, v_req.leg)
      on conflict (leg, phone) do update
        set name = excluded.name, note = excluded.note;
    end if;

    -- 이제 버스를 타는 사람이므로 "버스 안 탐" 자리는 필요 없다.
    delete from public.bus_passengers where phone = v_req.phone and leg = 'stay';

    update public.bus_requests set status = 'added' where id = v_req.id;
    return jsonb_build_object('status', 'ok');

  elsif p_action = 'request_reject' then
    update public.bus_requests set status = 'rejected' where id = (p_payload->>'id')::bigint;
    return jsonb_build_object('status', 'ok');

  elsif p_action = 'groups' then
    return jsonb_build_object(
      'status', 'ok',
      'registered', coalesce((select jsonb_agg(name order by name) from public.bus_groups), '[]'::jsonb),
      'all', public.bus_group_options()
    );

  elsif p_action = 'group_add' then
    insert into public.bus_groups(name)
    values (btrim(p_payload->>'name'))
    on conflict (name) do nothing;
    return jsonb_build_object('status', 'ok');

  elsif p_action = 'group_del' then
    delete from public.bus_groups where name = p_payload->>'name';
    return jsonb_build_object('status', 'ok');

  elsif p_action = 'upload' then
    if coalesce(p_payload->>'mode', 'add') = 'replace' then
      delete from public.bus_passengers where leg = v_leg;
    end if;
    for v_row in select * from jsonb_array_elements(p_payload->'rows') loop
      v_phone := public.bus_norm_phone(v_row->>'phone');
      if length(v_phone) < 8 then
        continue when btrim(coalesce(v_row->>'name','')) = '';
        v_old := public.bus_same_person(v_row->>'note', v_row->>'name');
        v_phone := coalesce(v_old, public.bus_missing_phone(v_row->>'note', v_row->>'name'));
      end if;

      insert into public.bus_passengers(name, phone, note, leg)
      values (btrim(v_row->>'name'),
              v_phone,
              nullif(btrim(coalesce(v_row->>'note','')), ''),
              v_leg)
      on conflict (leg, phone) do update
        set name = excluded.name, note = excluded.note;

      if (v_row ? 'night1') or (v_row ? 'night2') or (v_row ? 'gender') then
        update public.bus_passengers
           set night1 = case when v_row ? 'night1'
                             then coalesce((v_row->>'night1')::boolean, false) else night1 end,
               night2 = case when v_row ? 'night2'
                             then coalesce((v_row->>'night2')::boolean, false) else night2 end,
               gender = case when v_row ? 'gender'
                             then nullif(btrim(coalesce(v_row->>'gender','')), '') else gender end
         where phone = v_phone;
      end if;

      -- 예전 방식의 시트는 사람마다 방이 하나다.
      if (v_row ? 'room_label') or (v_row ? 'room_no') then
        delete from public.bus_room_slots where phone = v_phone;
        if public.bus_room_key(v_row->>'room_label', v_row->>'room_no') is not null then
          insert into public.bus_room_slots(phone, room_label, room_no, is_leader)
          values (v_phone,
                  nullif(btrim(coalesce(v_row->>'room_label','')), ''),
                  nullif(btrim(coalesce(v_row->>'room_no','')), ''),
                  coalesce((v_row->>'is_leader')::boolean, false))
          on conflict (phone, public.bus_room_key(room_label, room_no))
          do update set is_leader = excluded.is_leader;
        end if;
      end if;
    end loop;
    return jsonb_build_object('status', 'ok');

  elsif p_action = 'upload_sheet' then
    -- 통합 시트: 한 줄이 한 사람이고, 그 줄이 그 사람의 전부다.
    -- 시트에 실린 사람에 한해 편 구성과 방 배정을 시트대로 맞춘다.
    if coalesce(p_payload->>'mode', 'add') = 'replace' then
      delete from public.bus_room_slots;
      delete from public.bus_passengers;
      delete from public.bus_requests;
    end if;

    for v_row in select * from jsonb_array_elements(p_payload->'rows') loop
      continue when btrim(coalesce(v_row->>'name','')) = '';

      v_phone := public.bus_norm_phone(v_row->>'phone');
      if length(v_phone) < 8 then
        -- 연락처를 아직 못 받은 사람 — 자리표 번호로 명단에 올려 둔다.
        -- 다만 운영자가 이미 번호를 넣어 준 사람이라면(이름·소속이 같음)
        -- 시트에 아직 번호가 없더라도 그 사람으로 이어 붙인다.
        -- 안 그러면 시트를 다시 올릴 때마다 같은 사람이 하나씩 더 생긴다.
        v_old := public.bus_same_person(v_row->>'note', v_row->>'name');
        v_phone := coalesce(v_old, public.bus_missing_phone(v_row->>'note', v_row->>'name'));
      else
        -- 반대로 시트에 번호가 채워졌으면, 자리표로 올라가 있던 같은 사람을
        -- 걷어낸다. 방 배정은 아래에서 시트대로 다시 만들어진다.
        v_old := public.bus_missing_phone(v_row->>'note', v_row->>'name');
        delete from public.bus_room_slots where phone = v_old;
        delete from public.bus_passengers  where phone = v_old;
      end if;

      -- 'out' 을 그냥 붙이면 배열 리터럴로 읽혀 터진다. 타입을 못 박아 둔다.
      v_legs := array[]::text[];
      if coalesce((v_row->>'out')::boolean,  false) then v_legs := v_legs || 'out'::text;  end if;
      if coalesce((v_row->>'back')::boolean, false) then v_legs := v_legs || 'back'::text; end if;
      -- 버스를 안 타는 사람도 숙소 안내를 받아야 하므로 자리를 하나 둔다.
      if array_length(v_legs, 1) is null then v_legs := array['stay']; end if;

      delete from public.bus_passengers
       where phone = v_phone and not (leg = any(v_legs));

      foreach v_one in array v_legs loop
        insert into public.bus_passengers(name, phone, note, leg)
        values (btrim(v_row->>'name'),
                v_phone,
                nullif(btrim(coalesce(v_row->>'note','')), ''),
                v_one)
        on conflict (leg, phone) do update
          set name = excluded.name, note = excluded.note;
      end loop;

      update public.bus_passengers
         set night1 = case when v_row ? 'night1'
                           then coalesce((v_row->>'night1')::boolean, false) else night1 end,
             night2 = case when v_row ? 'night2'
                           then coalesce((v_row->>'night2')::boolean, false) else night2 end,
             gender = case when v_row ? 'gender'
                           then nullif(btrim(coalesce(v_row->>'gender','')), '') else gender end
       where phone = v_phone;

      -- 방 배정 — 한 사람이 방을 여러 개 가질 수 있다.
      if v_row ? 'rooms' then
        delete from public.bus_room_slots s
         where s.phone = v_phone
           and not exists (
             select 1 from jsonb_array_elements(v_row->'rooms') e
              where public.bus_room_key(e->>'label', e->>'no')
                    = public.bus_room_key(s.room_label, s.room_no));

        for v_rm in select * from jsonb_array_elements(v_row->'rooms') loop
          continue when public.bus_room_key(v_rm->>'label', v_rm->>'no') is null;
          insert into public.bus_room_slots(phone, room_label, room_no, is_leader)
          values (v_phone,
                  nullif(btrim(coalesce(v_rm->>'label','')), ''),
                  nullif(btrim(coalesce(v_rm->>'no','')), ''),
                  coalesce((v_rm->>'is_leader')::boolean, false))
          on conflict (phone, public.bus_room_key(room_label, room_no))
          do update set room_no   = excluded.room_no,
                        is_leader = excluded.is_leader;
        end loop;
      end if;
    end loop;
    return jsonb_build_object('status', 'ok');

  elsif p_action = 'copy_leg' then
    insert into public.bus_passengers(name, phone, note, leg)
    select name, phone, note, case when v_leg = 'out' then 'back' else 'out' end
      from public.bus_passengers where leg = v_leg
    on conflict (leg, phone) do update set name = excluded.name, note = excluded.note;
    return jsonb_build_object('status', 'ok');

  elsif p_action = 'undo' then
    update public.bus_passengers set boarded_at = null where id = (p_payload->>'id')::bigint;
    return jsonb_build_object('status', 'ok');

  elsif p_action = 'mark' then
    update public.bus_passengers set boarded_at = now()
      where id = (p_payload->>'id')::bigint and boarded_at is null;
    return jsonb_build_object('status', 'ok');

  elsif p_action = 'reset_all' then
    update public.bus_passengers set boarded_at = null where leg = v_leg;
    return jsonb_build_object('status', 'ok');

  elsif p_action = 'purge' then
    if coalesce(p_payload->>'scope','leg') = 'all' then
      delete from public.bus_room_slots;
      delete from public.bus_passengers;
      delete from public.bus_requests;
    else
      delete from public.bus_passengers where leg = v_leg;
      delete from public.bus_requests where leg = v_leg;
      -- 어느 편에도 안 남은 사람의 방 배정은 같이 걷어낸다.
      delete from public.bus_room_slots s
       where not exists (select 1 from public.bus_passengers p where p.phone = s.phone);
    end if;
    return jsonb_build_object('status', 'ok');

  elsif p_action = 'set_collecting' then
    insert into public.bus_config(key, value)
    values ('collecting_' || v_leg,
            case when coalesce((p_payload->>'open')::boolean, false) then 'on' else 'off' end)
    on conflict (key) do update set value = excluded.value;

    update public.bus_config
       set value = case when public.bus_leg_open('out') or public.bus_leg_open('back')
                        then 'on' else 'off' end
     where key = 'collecting';

    return jsonb_build_object(
      'status', 'ok',
      'collecting', jsonb_build_object('out',  public.bus_leg_open('out'),
                                       'back', public.bus_leg_open('back')));

  elsif p_action = 'set_leg' then
    if (p_payload->>'leg') in ('out','back') then
      update public.bus_config set value = p_payload->>'leg' where key = 'active_leg';
    end if;
    return jsonb_build_object('status', 'ok');

  elsif p_action = 'set_title' then
    update public.bus_config set value = coalesce(p_payload->>'title','') where key = 'event_title';
    return jsonb_build_object('status', 'ok');

  elsif p_action = 'set_code' then
    update public.bus_config set value = p_payload->>'code' where key = 'admin_code';
    return jsonb_build_object('status', 'ok');
  end if;

  return jsonb_build_object('status', 'unknown_action');
end;
$$;

revoke all on function public.bus_admin(text, text, jsonb) from public;
grant execute on function public.bus_admin(text, text, jsonb) to anon, authenticated, service_role;

-- ---------------------------------------------------------------- 한 명씩 넣기
-- 검색 결과에 성별을 싣고, 새로 등록할 때 성별을 함께 받는다.
create or replace function public.bus_people_admin(p_code text, p_action text,
                                                   p_payload jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_code  text;
  v_rows  jsonb;
  v_q     text := btrim(coalesce(p_payload->>'q', ''));
  v_qd    text;
  v_leg   text;
  v_name  text := btrim(coalesce(p_payload->>'name', ''));
  v_note  text := nullif(btrim(coalesce(p_payload->>'note', '')), '');
  v_phone text;
  v_room  text := btrim(coalesce(p_payload->>'room', ''));
  v_gen   text := nullif(btrim(coalesce(p_payload->>'gender', '')), '');
  v_lbl   text;
  v_no    text;
begin
  select value into v_code from public.bus_config where key = 'admin_code';
  if v_code is null or p_code is null or p_code <> v_code then
    return jsonb_build_object('status', 'denied');
  end if;

  -- ------------------------------------------------------------ 사람 찾기
  if p_action = 'search' then
    v_qd := public.bus_norm_phone(v_q);
    select coalesce(jsonb_agg(to_jsonb(t) order by t.note nulls last, t.name), '[]'::jsonb)
      into v_rows
      from (
        select p.phone,
               max(p.name)             as name,
               max(p.note)             as note,
               max(p.gender)           as gender,
               not public.bus_real_phone(max(p.phone)) as no_phone,
               bool_or(p.leg = 'out')  as rides_out,
               bool_or(p.leg = 'back') as rides_back,
               bool_or(p.night1)       as night1,
               bool_or(p.night2)       as night2,
               (select coalesce(jsonb_agg(public.bus_room_key(s.room_label, s.room_no) order by s.id),
                                '[]'::jsonb)
                  from public.bus_room_slots s where s.phone = p.phone) as rooms
          from public.bus_passengers p
         where v_q = ''
            or p.name ilike '%' || v_q || '%'
            or coalesce(p.note,'') ilike '%' || v_q || '%'
            or (length(v_qd) >= 3 and p.phone like '%' || v_qd || '%')
         group by p.phone
         limit 60
      ) t;
    return jsonb_build_object('status', 'ok', 'rows', v_rows,
                              'total', (select count(distinct phone) from public.bus_passengers));

  -- ------------------------------------------------------------ 편에 넣기
  elsif p_action = 'add' then
    v_leg := coalesce(p_payload->>'leg', 'out');
    if v_leg not in ('out','back') then
      return jsonb_build_object('status', 'invalid');
    end if;
    if v_name = '' then
      return jsonb_build_object('status', 'invalid');
    end if;

    v_phone := public.bus_norm_phone(p_payload->>'phone');
    if length(v_phone) < 8 then
      -- 번호를 아직 못 받은 사람. 이미 번호를 받아 둔 같은 사람이 있으면 그리로.
      v_phone := coalesce(public.bus_same_person(v_note, v_name),
                          public.bus_missing_phone(v_note, v_name));
    end if;

    if exists (select 1 from public.bus_passengers where leg = v_leg and phone = v_phone) then
      return jsonb_build_object('status', 'exists');
    end if;

    insert into public.bus_passengers(name, phone, note, leg, gender)
    values (v_name, v_phone, v_note, v_leg, v_gen)
    on conflict (leg, phone) do update
      set name = excluded.name, note = excluded.note;

    -- 성별은 편과 무관하니 그 사람의 모든 행에 함께 쓴다.
    if v_gen is not null then
      update public.bus_passengers set gender = v_gen where phone = v_phone;
    end if;

    -- 이제 버스를 타는 사람이므로 "버스 안 탐" 자리는 필요 없다.
    delete from public.bus_passengers where phone = v_phone and leg = 'stay';

    return jsonb_build_object('status', 'ok', 'phone', v_phone,
                              'no_phone', not public.bus_real_phone(v_phone));

  -- ------------------------------------------------------------ 편에서 빼기
  elsif p_action = 'del' then
    v_leg := coalesce(p_payload->>'leg', 'out');
    if v_leg not in ('out','back') then
      return jsonb_build_object('status', 'invalid');
    end if;
    v_phone := coalesce(p_payload->>'phone', '');

    -- 방 정보를 잃지 않도록 이름·소속을 먼저 챙겨 둔다.
    select max(name), max(note) into v_lbl, v_no
      from public.bus_passengers where phone = v_phone;

    delete from public.bus_passengers where leg = v_leg and phone = v_phone;

    -- 어느 편에도 안 남았는데 방은 있는 사람이면 "버스 안 탐" 자리로 돌려 놓는다.
    -- 여기서 명단 행이 사라지면 방 배정이 주인을 잃는다.
    if not exists (select 1 from public.bus_passengers where phone = v_phone)
       and exists (select 1 from public.bus_room_slots where phone = v_phone) then
      insert into public.bus_passengers(name, phone, note, leg)
      values (coalesce(nullif(btrim(coalesce(v_lbl,'')), ''), '(이름 없음)'), v_phone, v_no, 'stay')
      on conflict (leg, phone) do nothing;
    end if;
    return jsonb_build_object('status', 'ok');

  -- ------------------------------------------------------------ 방에 넣기
  elsif p_action = 'room_add' then
    if v_room = '' then
      return jsonb_build_object('status', 'invalid');
    end if;

    v_phone := public.bus_norm_phone(p_payload->>'phone');
    if length(v_phone) < 8 then
      if v_name = '' then
        return jsonb_build_object('status', 'invalid');
      end if;
      v_phone := coalesce(public.bus_same_person(v_note, v_name),
                          public.bus_missing_phone(v_note, v_name));
    end if;

    -- 명단에 없는 사람이면 "버스 안 탐" 으로 자리를 만들어 준다.
    if not exists (select 1 from public.bus_passengers where phone = v_phone) then
      if v_name = '' then
        return jsonb_build_object('status', 'invalid');
      end if;
      insert into public.bus_passengers(name, phone, note, leg, gender)
      values (v_name, v_phone, v_note, 'stay', v_gen);
    elsif v_gen is not null then
      update public.bus_passengers set gender = v_gen where phone = v_phone;
    end if;

    -- 이미 있는 방이면 그 방의 임시배정명·호수를 그대로 따라간다.
    select room_label, room_no into v_lbl, v_no
      from public.bus_room_slots
     where public.bus_room_key(room_label, room_no) = v_room
     limit 1;
    if not found then
      v_lbl := v_room; v_no := null;
    end if;

    insert into public.bus_room_slots(phone, room_label, room_no, is_leader)
    values (v_phone, v_lbl, v_no, coalesce((p_payload->>'is_leader')::boolean, false))
    on conflict (phone, public.bus_room_key(room_label, room_no))
    do update set is_leader = excluded.is_leader;

    return jsonb_build_object('status', 'ok', 'phone', v_phone);

  -- ------------------------------------------------------------ 방에서 빼기
  elsif p_action = 'room_del' then
    delete from public.bus_room_slots
     where phone = coalesce(p_payload->>'phone', '')
       and public.bus_room_key(room_label, room_no) = v_room;
    return jsonb_build_object('status', 'ok');

  -- ------------------------------------------------------------ 방장 지정
  elsif p_action = 'room_leader' then
    update public.bus_room_slots
       set is_leader = coalesce((p_payload->>'is_leader')::boolean, false)
     where phone = coalesce(p_payload->>'phone', '')
       and public.bus_room_key(room_label, room_no) = v_room;
    return jsonb_build_object('status', 'ok');
  end if;

  return jsonb_build_object('status', 'unknown_action');
end;
$$;

revoke all on function public.bus_people_admin(text, text, jsonb) from public;
grant execute on function public.bus_people_admin(text, text, jsonb)
  to anon, authenticated, service_role;
