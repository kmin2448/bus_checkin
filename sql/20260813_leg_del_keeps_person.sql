-- 편에서 한 명을 빼도 전체 명단에서는 사라지지 않게 한다.
--
-- 현황 화면에서 이름을 길게 눌러 그 사람만 빼는 동작이 생겼다(admin.html).
-- "가는 편에서 뺀다" 는 **그 편에 해당하지 않게 된다**는 뜻이지 명단에서
-- 지워진다는 뜻이 아니다. 그런데 지금까지 bus_people_admin 의 del 은
-- **방이 있는 사람만** 'stay'(버스 안 탐) 자리로 돌려 놓았다. 그래서 방이 없는
-- 사람을 편에서 빼면 그 사람 자체가 사라져, 다시 넣으려면 이름·번호를 손으로
-- 다시 쳐야 했다.
--
-- 바뀌는 곳은 del 한 군데다.
--   - 어느 편에도 안 남으면 **방이 있든 없든** 'stay' 자리를 남긴다.
--     명단 검색(search)에 그대로 잡히므로 "추가" 한 번으로 되돌릴 수 있다.
--   - 그 자리에 숙박일(night1 · night2)과 성별도 함께 옮긴다. 예전에는 새로 만든
--     'stay' 행이 기본값(false · null)이라 숙박 인원수가 어긋났다.
--
-- 나머지 동작은 20260808_gender.sql 의 정의 그대로다.

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
  v_n1    boolean;
  v_n2    boolean;
  v_kept  boolean := false;
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

    -- 편에서 빼면서 남겨 둔 'stay' 자리가 있으면 숙박일·성별을 그대로 물려받는다.
    select bool_or(night1), bool_or(night2), coalesce(v_gen, max(gender))
      into v_n1, v_n2, v_gen
      from public.bus_passengers where phone = v_phone;

    insert into public.bus_passengers(name, phone, note, leg, gender, night1, night2)
    values (v_name, v_phone, v_note, v_leg, v_gen,
            coalesce(v_n1, false), coalesce(v_n2, false))
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

    -- 행이 사라지기 전에 그 사람 정보를 챙겨 둔다.
    select max(name), max(note), max(gender), bool_or(night1), bool_or(night2)
      into v_lbl, v_no, v_gen, v_n1, v_n2
      from public.bus_passengers where phone = v_phone;

    if v_lbl is null then
      return jsonb_build_object('status', 'gone');
    end if;

    delete from public.bus_passengers where leg = v_leg and phone = v_phone;

    -- 어느 편에도 안 남았으면 "버스 안 탐" 자리로 돌려 놓는다.
    -- 여기서 명단 행이 사라지면 방 배정이 주인을 잃고, 전체 명단에서도 사라진다.
    if not exists (select 1 from public.bus_passengers where phone = v_phone) then
      insert into public.bus_passengers(name, phone, note, leg, gender, night1, night2)
      values (coalesce(nullif(btrim(coalesce(v_lbl,'')), ''), '(이름 없음)'),
              v_phone, v_no, 'stay', v_gen, coalesce(v_n1, false), coalesce(v_n2, false))
      on conflict (leg, phone) do nothing;
      v_kept := true;
    end if;

    -- kept = 이 사람이 이제 어느 편에도 안 타는 사람이 됐다는 뜻.
    return jsonb_build_object('status', 'ok', 'name', v_lbl, 'kept', v_kept);

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
  -- 방 배정만 푼다. 명단(가는 편·오는 편·stay)에는 그대로 남아 방 미배정이 된다.
  elsif p_action = 'room_del' then
    delete from public.bus_room_slots
     where phone = coalesce(p_payload->>'phone', '')
       and public.bus_room_key(room_label, room_no) = v_room;
    if not found then
      return jsonb_build_object('status', 'gone');
    end if;
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
