-- 한 사람에게 방 여러 개 · 연락처 없는 사람.
--
-- 두 가지를 고친다.
--
-- 1) 방 배정을 bus_passengers 의 컬럼에서 떼어 내 별도 표로 옮긴다.
--    지금까지는 사람 한 명이 방 하나였는데, 방을 두 개 잡아 둔 사람이 있다
--    (같은 사람이 시트에 두 줄로 적혀 방 배정이 하나 사라지던 문제).
--    bus_room_slots 에 (전화번호, 방) 한 쌍이 한 줄이면 몇 개든 들어간다.
--    방키 수령·반납 시각도 방에 딸린 것이므로 같이 옮긴다.
--
-- 2) 연락처를 아직 못 받은 사람도 명단에 올린다.
--    번호가 사람을 가르는 기준이라 빈 값으로 둘 수 없어서, '?소속/이름' 모양의
--    자리표 번호를 붙여 둔다. 숫자로 시작하지 않으므로 참가자가 번호를 넣어
--    조회하는 어떤 경로와도 겹치지 않는다. 운영자 화면에서 "연락처 추가 필요"
--    로 뜨고, 번호를 넣으면 명단과 방 배정에 한꺼번에 반영된다.
--
-- 숙박일(night1 · night2)은 사람에게 딸린 값이라 bus_passengers 에 그대로 둔다.
-- 방마다 며칠치인지는 그 방에 든 사람들의 숙박일로 센다.

-- ---------------------------------------------------------------- 헬퍼
-- 번호가 없는 사람의 자리표 번호. 이름과 소속이 같으면 늘 같은 값이 나오므로
-- 시트를 다시 올려도 같은 사람으로 이어진다.
create or replace function public.bus_missing_phone(p_note text, p_name text)
returns text
language sql immutable
as $$
  select '?' || coalesce(nullif(btrim(coalesce(p_note,'')), ''), '-')
             || '/' || btrim(coalesce(p_name,''))
$$;

-- 진짜 번호인지 — 자리표는 '?' 로 시작한다.
create or replace function public.bus_real_phone(p text)
returns boolean
language sql immutable
as $$
  select coalesce(p, '') ~ '^[0-9]'
$$;

-- 이름과 소속이 같으면서 이미 진짜 번호를 가진 사람의 번호(없으면 null).
-- 번호 없이 올라온 줄이 이미 번호를 받은 사람인지 가려낼 때 쓴다.
create or replace function public.bus_same_person(p_note text, p_name text)
returns text
language sql
stable
set search_path to 'public'
as $$
  select phone
    from public.bus_passengers
   where btrim(name) = btrim(coalesce(p_name,''))
     and coalesce(nullif(btrim(coalesce(note,'')), ''), '')
         = coalesce(nullif(btrim(coalesce(p_note,'')), ''), '')
     and public.bus_real_phone(phone)
   order by phone
   limit 1
$$;

-- ---------------------------------------------------------------- 방 배정 표
create table if not exists public.bus_room_slots(
  id         bigserial primary key,
  phone      text not null,
  room_label text,
  room_no    text,
  is_leader  boolean not null default false,
  key_out_at timestamptz,
  key_in_at  timestamptz
);

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'bus_room_slots_key_check') then
    alter table public.bus_room_slots
      add constraint bus_room_slots_key_check
      check (public.bus_room_key(room_label, room_no) is not null);
  end if;
end $$;

create unique index if not exists bus_room_slots_uk
  on public.bus_room_slots (phone, public.bus_room_key(room_label, room_no));

create index if not exists bus_room_slots_room_idx
  on public.bus_room_slots (public.bus_room_key(room_label, room_no));

-- 쓰던 방 배정을 옮긴다. 컬럼이 이미 없으면(두 번째 실행) 건너뛴다.
do $$
begin
  if exists (select 1 from information_schema.columns
              where table_schema = 'public' and table_name = 'bus_passengers'
                and column_name = 'room_label') then
    insert into public.bus_room_slots(phone, room_label, room_no, is_leader, key_out_at, key_in_at)
    select distinct on (phone)
           phone, room_label, room_no, is_leader, key_out_at, key_in_at
      from public.bus_passengers
     where public.bus_room_key(room_label, room_no) is not null
     order by phone, key_out_at desc nulls last
    on conflict do nothing;
  end if;
end $$;

alter table public.bus_passengers
  drop column if exists room_label,
  drop column if exists room_no,
  drop column if exists is_leader,
  drop column if exists key_out_at,
  drop column if exists key_in_at;

-- ---------------------------------------------------------------- 방 조회 헬퍼
-- 방 하나에 든 사람들. 이름과 숙박일은 명단(bus_passengers)에서 가져온다.
-- 방 이름만 알면 아무 방이나 들여다볼 수 있으므로 security definer 로 두지 않고
-- anon 에게도 주지 않는다. 이 함수를 부르는 쪽(bus_room_info 등)이 이미
-- security definer 라 소유자 권한으로 실행된다.
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
           'night1',    m.night1,
           'night2',    m.night2)
           order by m.is_leader desc, m.name), '[]'::jsonb)
    from (
      select s.phone,
             bool_or(s.is_leader) as is_leader,
             max(p.name)          as name,
             bool_or(p.night1)    as night1,
             bool_or(p.night2)    as night2
        from public.bus_room_slots s
        join public.bus_passengers p on p.phone = s.phone
       where public.bus_room_key(s.room_label, s.room_no) = p_rkey
       group by s.phone
    ) m
$$;

-- 방장(없으면 null). 위와 같은 이유로 anon 에게 주지 않는다.
create or replace function public.bus_room_leader(p_rkey text)
returns jsonb
language sql
stable
set search_path to 'public'
as $$
  select jsonb_build_object(
           'name',  max(p.name),
           'phone', case when public.bus_real_phone(s.phone) then s.phone else '' end)
    from public.bus_room_slots s
    join public.bus_passengers p on p.phone = s.phone
   where public.bus_room_key(s.room_label, s.room_no) = p_rkey
     and s.is_leader
   group by s.phone
   order by s.phone
   limit 1
$$;

-- ---------------------------------------------------------------- 참가자
-- 방을 여러 개 가진 사람이 있어 rooms 배열로 돌려준다.
-- 예전에 배포된 화면을 위해 첫 방의 값은 예전 자리에도 그대로 담아 둔다.
create or replace function public.bus_room_info(p_phone text)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $$
declare
  v_phone text := public.bus_norm_phone(p_phone);
  v_n1    boolean;
  v_n2    boolean;
  v_rooms jsonb;
  v_one   jsonb;
begin
  if length(v_phone) < 8 then
    return jsonb_build_object('status','invalid');
  end if;

  select bool_or(night1), bool_or(night2)
    into v_n1, v_n2
    from public.bus_passengers
   where phone = v_phone;

  if v_n1 is null then                      -- 명단에 아예 없음
    return jsonb_build_object('status','not_found');
  end if;

  select coalesce(jsonb_agg(t order by t.room), '[]'::jsonb)
    into v_rooms
    from (
      select public.bus_room_key(s.room_label, s.room_no) as room,
             coalesce(nullif(btrim(coalesce(s.room_no,'')),''), '')    as room_no,
             coalesce(nullif(btrim(coalesce(s.room_label,'')),''), '') as room_label,
             s.is_leader,
             public.bus_room_leader(public.bus_room_key(s.room_label, s.room_no))  as leader,
             public.bus_room_members(public.bus_room_key(s.room_label, s.room_no)) as members
        from public.bus_room_slots s
       where s.phone = v_phone
    ) t;

  if jsonb_array_length(v_rooms) = 0 then
    return jsonb_build_object('status','none');   -- 명단엔 있으나 방 배정 전
  end if;

  v_one := v_rooms->0;

  return jsonb_build_object(
    'status','ok',
    'rooms',          v_rooms,
    'night1',         coalesce(v_n1, false),
    'night2',         coalesce(v_n2, false),
    -- 아래 넷은 예전 화면 호환용(첫 방)
    'room_no',        v_one->>'room_no',
    'room_label',     v_one->>'room_label',
    'is_leader',      coalesce((v_one->>'is_leader')::boolean, false),
    'leader',         v_one->'leader',
    'members',        v_one->'members',
    'key_guide',      coalesce((select value from public.bus_config where key='room_key_guide'), ''),
    'checkout_guide', coalesce((select value from public.bus_config where key='checkout_guide'), ''),
    'title',          coalesce((select value from public.bus_config where key='event_title'), '')
  );
end;
$$;

-- ---------------------------------------------------------------- 운영자(방)
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
          public.bus_room_members(g.rkey) as members,
          coalesce(max(nullif(btrim(coalesce(g.room_no,'')),'')), g.rkey) as sort
        from (
          select s.id, s.room_label, s.room_no, s.key_out_at, s.key_in_at,
                 bool_or(p.night1) as night1,
                 bool_or(p.night2) as night2,
                 public.bus_room_key(s.room_label, s.room_no) as rkey
            from public.bus_room_slots s
            join public.bus_passengers p on p.phone = s.phone
           group by s.id, s.room_label, s.room_no, s.key_out_at, s.key_in_at
        ) g
        group by g.rkey
      ) r;

    return jsonb_build_object(
      'status','ok',
      'rooms', v_rows,
      'unassigned', (select count(distinct p.phone) from public.bus_passengers p
                      where not exists (select 1 from public.bus_room_slots s
                                         where s.phone = p.phone)),
      'nights', jsonb_build_object(
        'n1', (select count(distinct phone) from public.bus_passengers where night1),
        'n2', (select count(distinct phone) from public.bus_passengers where night2)),
      'title', coalesce((select value from public.bus_config where key='event_title'), '')
    );

  elsif p_action = 'key_out' then
    update public.bus_room_slots
       set key_out_at = now(), key_in_at = null
     where public.bus_room_key(room_label, room_no) = v_room;
    return jsonb_build_object('status','ok');

  elsif p_action = 'key_in' then
    update public.bus_room_slots
       set key_in_at = now()
     where public.bus_room_key(room_label, room_no) = v_room
       and key_out_at is not null;
    return jsonb_build_object('status','ok');

  elsif p_action = 'undo_in' then     -- 반납 취소 → 다시 "사용 중"
    update public.bus_room_slots
       set key_in_at = null
     where public.bus_room_key(room_label, room_no) = v_room;
    return jsonb_build_object('status','ok');

  elsif p_action = 'undo_out' then    -- 수령 취소 → 처음 상태로
    update public.bus_room_slots
       set key_out_at = null, key_in_at = null
     where public.bus_room_key(room_label, room_no) = v_room;
    return jsonb_build_object('status','ok');

  elsif p_action = 'set_room_no' then
    update public.bus_room_slots
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
               note,
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
        select q.phone, q.name, q.note, q.night1, q.night2, q.rides_out, q.rides_back,
               q.no_phone,
               s.room_label, s.room_no, coalesce(s.is_leader, false) as is_leader
          from (
            select p.phone,
                   max(p.name)            as name,
                   max(p.note)            as note,
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

      if (v_row ? 'night1') or (v_row ? 'night2') then
        update public.bus_passengers
           set night1 = case when v_row ? 'night1'
                             then coalesce((v_row->>'night1')::boolean, false) else night1 end,
               night2 = case when v_row ? 'night2'
                             then coalesce((v_row->>'night2')::boolean, false) else night2 end
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
                           then coalesce((v_row->>'night2')::boolean, false) else night2 end
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

-- ---------------------------------------------------------------- 권한
alter table public.bus_room_slots enable row level security;

-- 방 목록을 통째로 꺼내 볼 수 있는 두 헬퍼(bus_room_members · bus_room_leader)는
-- 아무에게도 주지 않는다. 소유자 권한으로 도는 함수 안에서만 쓰인다.
revoke all on function public.bus_missing_phone(text, text) from public;
revoke all on function public.bus_real_phone(text)          from public;
revoke all on function public.bus_same_person(text, text)   from public;
revoke all on function public.bus_room_members(text)        from public;
revoke all on function public.bus_room_leader(text)         from public;
revoke all on function public.bus_admin(text, text, jsonb)  from public;
revoke all on function public.bus_room_info(text)           from public;
revoke all on function public.bus_room_admin(text, text, jsonb) from public;

grant execute on function public.bus_missing_phone(text, text)     to anon, authenticated, service_role;
grant execute on function public.bus_real_phone(text)              to anon, authenticated, service_role;
grant execute on function public.bus_admin(text, text, jsonb)      to anon, authenticated, service_role;
grant execute on function public.bus_room_info(text)               to anon, authenticated, service_role;
grant execute on function public.bus_room_admin(text, text, jsonb) to anon, authenticated, service_role;
