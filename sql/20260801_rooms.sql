-- 숙박(방배정 · 방키 수불) 기능.
--
-- 기존 데이터에는 손대지 않는다: bus_passengers 에 컬럼만 추가하고,
-- 함수는 새로 만들거나(bus_room_*) 통째로 재정의(bus_admin)한다.
--
-- 설계 메모
-- - room_label(임시배정명)과 room_no(실제 호수)를 분리해 둔다. 사전에는
--   엑셀로 room_label 만 배정하고, 실제 호수는 현장에서 키를 나눠 주며
--   입력한다(사전 입력도 가능).
-- - 방 식별자(rkey)는 room_label 이 있으면 room_label, 없으면 room_no.
-- - 명단은 편(leg)별로 행이 따로 있으므로, 숙박 정보는 전화번호 기준으로
--   두 편 행에 똑같이 반영한다. 키 수령/반납도 방 단위로 두 편 모두 갱신.

-- ---------------------------------------------------------------- 컬럼
alter table public.bus_passengers
  add column if not exists room_label text,
  add column if not exists room_no    text,
  add column if not exists is_leader  boolean not null default false,
  add column if not exists key_out_at timestamptz,
  add column if not exists key_in_at  timestamptz;

-- 참가자 화면에 보여 줄 안내 문구 (manage.html 에서 편집)
insert into public.bus_config(key, value) values ('room_key_guide','')
on conflict (key) do nothing;
insert into public.bus_config(key, value) values ('checkout_guide','')
on conflict (key) do nothing;

-- ---------------------------------------------------------------- 헬퍼
-- 방 식별자: 임시배정명 우선, 없으면 실제 호수. 둘 다 없으면 null(미배정).
create or replace function public.bus_room_key(p_label text, p_no text)
returns text
language sql immutable
as $$
  select coalesce(nullif(btrim(coalesce(p_label,'')),''),
                  nullif(btrim(coalesce(p_no,'')),''))
$$;

-- ---------------------------------------------------------------- 참가자
-- 본인 방 정보만 돌려준다. 전체 배정표는 어떤 경로로도 노출하지 않는다.
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
  v_key     text;
  v_members jsonb;
  v_leader  jsonb;
begin
  if length(v_phone) < 8 then
    return jsonb_build_object('status','invalid');
  end if;

  select room_label, room_no, is_leader
    into v_label, v_no, v_me
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
           'name', m.name, 'phone', m.phone, 'is_leader', m.is_leader)
           order by m.is_leader desc, m.name), '[]'::jsonb)
    into v_members
    from (select distinct on (phone) phone, name, is_leader
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
    'leader',         v_leader,   -- 방장이 지정 안 됐으면 null
    'members',        v_members,
    'key_guide',      coalesce((select value from public.bus_config where key='room_key_guide'), ''),
    'checkout_guide', coalesce((select value from public.bus_config where key='checkout_guide'), ''),
    'title',          coalesce((select value from public.bus_config where key='event_title'), '')
  );
end;
$$;

-- ---------------------------------------------------------------- 운영자
-- 방 단위 목록과 키 수령/반납, 실제 호수 입력, 안내 문구 저장.
-- 운영 코드(bus_config.admin_code)로 잠근다.
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
          jsonb_agg(jsonb_build_object('name', g.name, 'phone', g.phone,
                                       'is_leader', g.is_leader)
                    order by g.is_leader desc, g.name) as members,
          coalesce(max(nullif(btrim(coalesce(g.room_no,'')),'')), g.rkey) as sort
        from (select distinct on (phone) phone, name, is_leader,
                     room_label, room_no, key_out_at, key_in_at,
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

-- ---------------------------------------------------------------- 업로드 확장
-- bus_admin 의 upload 가 숙박 열(room_label / room_no / is_leader)을
-- "있으면 반영, 없으면 무시"하도록 통째로 재정의한다. 그 외 동작은 그대로.
-- 숙박 정보는 전화번호 기준으로 양쪽 편 행에 함께 반영한다.
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
          from public.bus_passengers group by leg
      ) s;

    return jsonb_build_object(
      'status', 'ok',
      'leg', v_leg,
      'rows', v_rows,
      'totals', coalesce(v_tot, '{}'::jsonb),
      'pending', (select count(*) from public.bus_requests where status = 'pending'),
      'open', public.bus_leg_open(v_leg),
      'collecting', jsonb_build_object('out',  public.bus_leg_open('out'),
                                       'back', public.bus_leg_open('back')),
      'active_leg', coalesce((select value from public.bus_config where key = 'active_leg'), 'out'),
      'title', coalesce((select value from public.bus_config where key = 'event_title'), '')
    );

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
      if (v_row ? 'room_label') or (v_row ? 'room_no') or (v_row ? 'is_leader') then
        update public.bus_passengers
           set room_label = case when v_row ? 'room_label'
                                 then nullif(btrim(coalesce(v_row->>'room_label','')), '')
                                 else room_label end,
               room_no    = case when v_row ? 'room_no'
                                 then nullif(btrim(coalesce(v_row->>'room_no','')), '')
                                 else room_no end,
               is_leader  = case when v_row ? 'is_leader'
                                 then coalesce((v_row->>'is_leader')::boolean, false)
                                 else is_leader end
         where phone = v_phone;
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
revoke all on function public.bus_room_key(text, text) from public;
revoke all on function public.bus_room_info(text) from public;
revoke all on function public.bus_room_admin(text, text, jsonb) from public;

grant execute on function public.bus_room_key(text, text)          to anon, authenticated, service_role;
grant execute on function public.bus_room_info(text)               to anon, authenticated, service_role;
grant execute on function public.bus_room_admin(text, text, jsonb) to anon, authenticated, service_role;
