-- 한 명씩 넣고 빼기.
--
-- 명단 전체를 다루는 일(통합 시트 업로드 · 삭제 · 설정)은 manage.html 한 곳에서만
-- 한다. 대신 현장에서 자주 생기는 "이 사람 한 명만 넣어 주세요" 는 보고 있던
-- 화면에서 바로 되어야 한다. 그래서 탑승 현황(admin.html)과 방키 수불(rooms.html)에
-- 한 명 추가를 두고, 그 뒤를 받치는 함수를 여기에 만든다.
--
-- 넣는 방법은 두 가지다.
--   1) 이미 명단에 있는 사람을 찾아서 이 편 / 이 방에 넣기
--      (다른 편에만 있던 사람, 숙박만 하던 사람이 대부분이다)
--   2) 아예 새로운 사람으로 등록하기
--
-- bus_admin 이 이미 길어서 통째로 다시 정의하지 않고 함수를 따로 뒀다.
-- 보호 방식은 같다 — 운영 코드(bus_config.admin_code)로 잠근다.

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

    insert into public.bus_passengers(name, phone, note, leg)
    values (v_name, v_phone, v_note, v_leg)
    on conflict (leg, phone) do update
      set name = excluded.name, note = excluded.note;

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
      insert into public.bus_passengers(name, phone, note, leg)
      values (v_name, v_phone, v_note, 'stay');
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
