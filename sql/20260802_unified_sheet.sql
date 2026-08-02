-- 통합 시트 하나로 관리하기.
--
-- 지금까지는 가는 편 명단 / 오는 편 명단 / 숙박(방배정)을 따로 올렸다.
-- 앞으로는 엑셀 한 장에 네 가지가 모두 들어간다.
--
--   팀명 · 이름 · 소속 대학 · 소속 학과 · 학번 · 연락처 · 성별
--   방배정 (가안) · 객실번호 · 방장 (방키수령)
--   1일차 숙박 · 2일차 숙박 · 가는차 탑승 · 오는차 탑승 · 비고
--
-- 설계 메모
-- - 사람 한 명은 시트에서 한 줄이지만, 명단 테이블에서는 편(leg)마다 행이 하나다.
--   "가는차 탑승" 표시가 있으면 out 행, "오는차 탑승" 표시가 있으면 back 행을 만든다.
-- - 버스를 아예 타지 않고 숙박만 하는 사람도 있다(외부 강사 · 자차 이동).
--   이런 사람은 leg='stay' 행 하나로 둔다. 버스 화면은 leg in ('out','back') 만
--   보므로 탑승 명단에는 나타나지 않고, 방 관련 조회는 편을 가리지 않으므로
--   숙소 안내는 그대로 받는다.
-- - 숙박일(night1 · night2)은 편과 무관하니 방 정보처럼 전화번호 기준으로
--   그 사람의 모든 행에 함께 쓴다.
-- - 소속은 "소속 대학 + 팀명" 을 합친 한 값(note)으로 관리한다. 합치는 일은
--   업로드 화면(manage.html)에서 하고, 여기서는 받은 값을 그대로 넣는다.

-- ---------------------------------------------------------------- 컬럼
alter table public.bus_passengers
  add column if not exists night1 boolean not null default false,
  add column if not exists night2 boolean not null default false;

-- leg 에 'stay' 를 허용한다. 기존 체크 제약의 이름을 모르므로 leg 를 언급하는
-- 체크 제약을 찾아 걷어내고 새로 붙인다.
do $$
declare c record;
begin
  for c in
    select conname
      from pg_constraint
     where conrelid = 'public.bus_passengers'::regclass
       and contype = 'c'
       and pg_get_constraintdef(oid) ilike '%leg%'
  loop
    execute format('alter table public.bus_passengers drop constraint %I', c.conname);
  end loop;
end $$;

alter table public.bus_passengers
  add constraint bus_passengers_leg_check check (leg in ('out','back','stay'));

-- ---------------------------------------------------------------- 참가자
-- 본인 방 정보에 숙박일을 얹는다. 전체 배정표는 여전히 노출하지 않는다.
create or replace function public.bus_room_info(p_phone text)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $$
declare
  v_phone   text := public.bus_norm_phone(p_phone);
  v_label   text;
  v_no      text;
  v_me      boolean;
  v_n1      boolean;
  v_n2      boolean;
  v_key     text;
  v_members jsonb;
  v_leader  jsonb;
begin
  if length(v_phone) < 8 then
    return jsonb_build_object('status','invalid');
  end if;

  select room_label, room_no, is_leader, night1, night2
    into v_label, v_no, v_me, v_n1, v_n2
    from public.bus_passengers
   where phone = v_phone
     and public.bus_room_key(room_label, room_no) is not null
   order by is_leader desc
   limit 1;

  if not found then
    if exists (select 1 from public.bus_passengers where phone = v_phone) then
      return jsonb_build_object('status','none');   -- 명단엔 있으나 방 배정 전
    end if;
    return jsonb_build_object('status','not_found');
  end if;

  v_key := public.bus_room_key(v_label, v_no);

  select coalesce(jsonb_agg(jsonb_build_object(
           'name', m.name, 'phone', m.phone, 'is_leader', m.is_leader,
           'night1', m.night1, 'night2', m.night2)
           order by m.is_leader desc, m.name), '[]'::jsonb)
    into v_members
    from (select distinct on (phone) phone, name, is_leader, night1, night2
            from public.bus_passengers
           where public.bus_room_key(room_label, room_no) = v_key
           order by phone, is_leader desc) m;

  select jsonb_build_object('name', m.name, 'phone', m.phone)
    into v_leader
    from (select distinct on (phone) phone, name
            from public.bus_passengers
           where public.bus_room_key(room_label, room_no) = v_key
             and is_leader
           order by phone) m
   limit 1;

  return jsonb_build_object(
    'status','ok',
    'room_no',        coalesce(nullif(btrim(coalesce(v_no,'')),''), ''),
    'room_label',     coalesce(nullif(btrim(coalesce(v_label,'')),''), ''),
    'is_leader',      coalesce(v_me, false),
    'night1',         coalesce(v_n1, false),
    'night2',         coalesce(v_n2, false),
    'leader',         v_leader,   -- 방장이 지정 안 됐으면 null
    'members',        v_members,
    'key_guide',      coalesce((select value from public.bus_config where key='room_key_guide'), ''),
    'checkout_guide', coalesce((select value from public.bus_config where key='checkout_guide'), ''),
    'title',          coalesce((select value from public.bus_config where key='event_title'), '')
  );
end;
$$;

-- ---------------------------------------------------------------- 운영자(방)
-- 방 목록에 숙박일별 인원(n1 · n2)을 얹는다. 1일차와 2일차 이용자가 다른 방이
-- 있어서(예: 하루만 묵는 사람) 방마다 며칠치인지 보여 줘야 한다.
create or replace function public.bus_room_admin(p_code text, p_action text,
                                                 p_payload jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_code text;
  v_room text := btrim(coalesce(p_payload->>'room',''));
  v_rows jsonb;
begin
  select value into v_code from public.bus_config where key = 'admin_code';
  if v_code is null or p_code is null or p_code <> v_code then
    return jsonb_build_object('status','denied');
  end if;

  if p_action = 'list' then
    select coalesce(jsonb_agg(to_jsonb(r) - 'sort' order by r.sort), '[]'::jsonb)
      into v_rows
      from (
        select
          g.rkey as room,
          coalesce(max(nullif(btrim(coalesce(g.room_no,'')),'')), '')    as room_no,
          coalesce(max(nullif(btrim(coalesce(g.room_label,'')),'')), '') as room_label,
          case when max(g.key_in_at)  is not null then 'in'
               when max(g.key_out_at) is not null then 'out'
               else 'pending' end as state,
          to_char(max(g.key_out_at) at time zone 'Asia/Seoul','HH24:MI') as out_at,
          to_char(max(g.key_in_at)  at time zone 'Asia/Seoul','HH24:MI') as in_at,
          count(*) filter (where g.night1) as n1,
          count(*) filter (where g.night2) as n2,
          jsonb_agg(jsonb_build_object('name', g.name, 'phone', g.phone,
                                       'is_leader', g.is_leader,
                                       'night1', g.night1, 'night2', g.night2)
                    order by g.is_leader desc, g.name) as members,
          coalesce(max(nullif(btrim(coalesce(g.room_no,'')),'')), g.rkey) as sort
        from (select distinct on (phone) phone, name, is_leader,
                     room_label, room_no, key_out_at, key_in_at, night1, night2,
                     public.bus_room_key(room_label, room_no) as rkey
                from public.bus_passengers
               where public.bus_room_key(room_label, room_no) is not null
               order by phone, key_out_at desc nulls last) g
        group by g.rkey
      ) r;

    return jsonb_build_object(
      'status','ok',
      'rooms', v_rows,
      'unassigned', (select count(distinct phone) from public.bus_passengers
                      where public.bus_room_key(room_label, room_no) is null),
      'nights', jsonb_build_object(
        'n1', (select count(distinct phone) from public.bus_passengers where night1),
        'n2', (select count(distinct phone) from public.bus_passengers where night2)),
      'title', coalesce((select value from public.bus_config where key='event_title'), '')
    );

  elsif p_action = 'key_out' then
    update public.bus_passengers
       set key_out_at = now(), key_in_at = null
     where public.bus_room_key(room_label, room_no) = v_room;
    return jsonb_build_object('status','ok');

  elsif p_action = 'key_in' then
    update public.bus_passengers
       set key_in_at = now()
     where public.bus_room_key(room_label, room_no) = v_room
       and key_out_at is not null;
    return jsonb_build_object('status','ok');

  elsif p_action = 'undo_in' then     -- 반납 취소 → 다시 "사용 중"
    update public.bus_passengers
       set key_in_at = null
     where public.bus_room_key(room_label, room_no) = v_room;
    return jsonb_build_object('status','ok');

  elsif p_action = 'undo_out' then    -- 수령 취소 → 처음 상태로
    update public.bus_passengers
       set key_out_at = null, key_in_at = null
     where public.bus_room_key(room_label, room_no) = v_room;
    return jsonb_build_object('status','ok');

  elsif p_action = 'set_room_no' then
    update public.bus_passengers
       set room_no = nullif(btrim(coalesce(p_payload->>'no','')), '')
     where public.bus_room_key(room_label, room_no) = v_room;
    return jsonb_build_object('status','ok');

  elsif p_action = 'guides' then
    return jsonb_build_object(
      'status','ok',
      'key_guide',      coalesce((select value from public.bus_config where key='room_key_guide'), ''),
      'checkout_guide', coalesce((select value from public.bus_config where key='checkout_guide'), ''));

  elsif p_action = 'set_guides' then
    insert into public.bus_config(key, value)
    values ('room_key_guide', coalesce(p_payload->>'key_guide',''))
    on conflict (key) do update set value = excluded.value;
    insert into public.bus_config(key, value)
    values ('checkout_guide', coalesce(p_payload->>'checkout_guide',''))
    on conflict (key) do update set value = excluded.value;
    return jsonb_build_object('status','ok');
  end if;

  return jsonb_build_object('status','unknown_action');
end;
$$;

-- ---------------------------------------------------------------- 운영자(명단)
-- 통합 시트용 동작 두 개를 더한다.
--   upload_sheet — 시트 한 장으로 두 편 명단 + 숙박을 한 번에 반영
--   sheet        — 지금 들어 있는 자료를 같은 형식으로 되돌려 준다(내려받기용)
-- 기존 upload(편 하나짜리)는 그대로 남겨 둔다.
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
  v_rows  jsonb;
  v_tot   jsonb;
  v_req   public.bus_requests%rowtype;
  v_phone text;
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
        select id, name, phone, note,
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
      'pending', (select count(*) from public.bus_requests where status = 'pending'),
      'open', public.bus_leg_open(v_leg),
      'collecting', jsonb_build_object('out',  public.bus_leg_open('out'),
                                       'back', public.bus_leg_open('back')),
      'active_leg', coalesce((select value from public.bus_config where key = 'active_leg'), 'out'),
      'title', coalesce((select value from public.bus_config where key = 'event_title'), '')
    );

  elsif p_action = 'sheet' then
    -- 사람 한 명에 한 줄. 편별로 흩어진 행을 전화번호로 다시 모은다.
    select coalesce(jsonb_agg(to_jsonb(t) order by t.note nulls last, t.name), '[]'::jsonb)
      into v_rows
      from (
        select p.phone,
               max(p.name)                      as name,
               max(p.note)                      as note,
               max(p.room_label)                as room_label,
               max(p.room_no)                   as room_no,
               bool_or(p.is_leader)             as is_leader,
               bool_or(p.night1)                as night1,
               bool_or(p.night2)                as night2,
               bool_or(p.leg = 'out')           as rides_out,
               bool_or(p.leg = 'back')          as rides_back
          from public.bus_passengers p
         group by p.phone
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
    return jsonb_build_object('status', 'ok', 'rows', v_rows);

  elsif p_action = 'request_approve' then
    select * into v_req from public.bus_requests where id = (p_payload->>'id')::bigint;
    if not found then return jsonb_build_object('status', 'gone'); end if;

    if v_req.kind = 'fix' and v_req.target_id is not null
       and exists (select 1 from public.bus_passengers where id = v_req.target_id) then
      delete from public.bus_passengers
       where leg = v_req.leg and phone = v_req.phone and id <> v_req.target_id;
      update public.bus_passengers
         set phone = v_req.phone,
             name  = v_req.name,
             note  = coalesce(v_req.note, note)
       where id = v_req.target_id;
    else
      insert into public.bus_passengers(name, phone, note, leg)
      values (v_req.name, v_req.phone, v_req.note, v_req.leg)
      on conflict (leg, phone) do update
        set name = excluded.name, note = excluded.note;
    end if;

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

      insert into public.bus_passengers(name, phone, note, leg)
      values (btrim(v_row->>'name'),
              v_phone,
              nullif(btrim(coalesce(v_row->>'note','')), ''),
              v_leg)
      on conflict (leg, phone) do update
        set name = excluded.name, note = excluded.note;

      -- 숙박 열: 시트에 있으면 반영, 없으면 그대로 둔다.
      -- 편과 무관한 정보라 같은 번호의 모든 행(양쪽 편)에 함께 쓴다.
      if (v_row ? 'room_label') or (v_row ? 'room_no') or (v_row ? 'is_leader')
         or (v_row ? 'night1') or (v_row ? 'night2') then
        update public.bus_passengers
           set room_label = case when v_row ? 'room_label'
                                 then nullif(btrim(coalesce(v_row->>'room_label','')), '')
                                 else room_label end,
               room_no    = case when v_row ? 'room_no'
                                 then nullif(btrim(coalesce(v_row->>'room_no','')), '')
                                 else room_no end,
               is_leader  = case when v_row ? 'is_leader'
                                 then coalesce((v_row->>'is_leader')::boolean, false)
                                 else is_leader end,
               night1     = case when v_row ? 'night1'
                                 then coalesce((v_row->>'night1')::boolean, false)
                                 else night1 end,
               night2     = case when v_row ? 'night2'
                                 then coalesce((v_row->>'night2')::boolean, false)
                                 else night2 end
         where phone = v_phone;
      end if;
    end loop;
    return jsonb_build_object('status', 'ok');

  elsif p_action = 'upload_sheet' then
    -- 통합 시트: 한 줄이 한 사람이고, 그 줄이 그 사람의 전부다.
    -- 시트에 실린 사람에 한해 편 구성을 시트대로 맞춘다(빠진 편의 행은 지운다).
    if coalesce(p_payload->>'mode', 'add') = 'replace' then
      delete from public.bus_passengers;
      delete from public.bus_requests;
    end if;

    for v_row in select * from jsonb_array_elements(p_payload->'rows') loop
      v_phone := public.bus_norm_phone(v_row->>'phone');
      continue when length(v_phone) < 8;

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
         set room_label = case when v_row ? 'room_label'
                               then nullif(btrim(coalesce(v_row->>'room_label','')), '')
                               else room_label end,
             room_no    = case when v_row ? 'room_no'
                               then nullif(btrim(coalesce(v_row->>'room_no','')), '')
                               else room_no end,
             is_leader  = case when v_row ? 'is_leader'
                               then coalesce((v_row->>'is_leader')::boolean, false)
                               else is_leader end,
             night1     = case when v_row ? 'night1'
                               then coalesce((v_row->>'night1')::boolean, false)
                               else night1 end,
             night2     = case when v_row ? 'night2'
                               then coalesce((v_row->>'night2')::boolean, false)
                               else night2 end
       where phone = v_phone;
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
      delete from public.bus_passengers;
      delete from public.bus_requests;
    else
      delete from public.bus_passengers where leg = v_leg;
      delete from public.bus_requests where leg = v_leg;
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

-- ---------------------------------------------------------------- 권한
revoke all on function public.bus_admin(text, text, jsonb) from public;
revoke all on function public.bus_room_info(text) from public;
revoke all on function public.bus_room_admin(text, text, jsonb) from public;

grant execute on function public.bus_admin(text, text, jsonb)      to anon, authenticated, service_role;
grant execute on function public.bus_room_info(text)               to anon, authenticated, service_role;
grant execute on function public.bus_room_admin(text, text, jsonb) to anon, authenticated, service_role;
