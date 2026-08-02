-- 방장이 자기 방 방키를 직접 수령·반납 처리한다.
--
-- 지금까지 방키 수불은 운영자 화면에서만 눌렀다. 그런데 실제로 키를 받아 가는
-- 사람은 방장이고, 반납도 방장이 한다. 운영자가 옆에 붙어 대신 눌러 주는 대신
-- 방장이 자기 화면에서 바로 누르게 한다.
--
-- 누가 눌렀는지는 전화번호로 가린다. 탑승 확인과 같은 신뢰 수준이다 —
-- 본인 번호를 넣어야 하고, 그 방의 방장으로 등록된 사람만 통과한다.
-- 방장이 아니면 denied 를 돌려주고 아무것도 바꾸지 않는다.
--
-- 참가자 화면이 닫혀 있으면(collecting_room = off) 이것도 막는다.

create or replace function public.bus_room_self(p_phone text, p_action text, p_room text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_phone text := public.bus_norm_phone(p_phone);
  v_room  text := btrim(coalesce(p_room, ''));
  v_out   timestamptz;
  v_in    timestamptz;
begin
  if not public.bus_room_open() then
    return jsonb_build_object('status', 'closed');
  end if;

  if length(v_phone) < 8 or v_room = '' then
    return jsonb_build_object('status', 'invalid');
  end if;

  -- 그 방의 방장으로 등록된 사람인가
  if not exists (
    select 1 from public.bus_room_slots
     where phone = v_phone
       and public.bus_room_key(room_label, room_no) = v_room
       and is_leader
  ) then
    return jsonb_build_object('status', 'denied');
  end if;

  if p_action = 'key_out' then
    update public.bus_room_slots
       set key_out_at = now(), key_in_at = null
     where public.bus_room_key(room_label, room_no) = v_room;

  elsif p_action = 'key_in' then
    update public.bus_room_slots
       set key_in_at = now()
     where public.bus_room_key(room_label, room_no) = v_room
       and key_out_at is not null;

  else
    return jsonb_build_object('status', 'unknown_action');
  end if;

  select max(key_out_at), max(key_in_at) into v_out, v_in
    from public.bus_room_slots
   where public.bus_room_key(room_label, room_no) = v_room;

  return jsonb_build_object(
    'status', 'ok',
    'state',  case when v_in is not null then 'in'
                   when v_out is not null then 'out' else 'pending' end,
    'out_at', to_char(v_out at time zone 'Asia/Seoul', 'HH24:MI'),
    'in_at',  to_char(v_in  at time zone 'Asia/Seoul', 'HH24:MI'));
end;
$$;

-- ---------------------------------------------------------------- 참가자
-- 방마다 지금 키 상태를 함께 돌려준다. 방장 화면에 어떤 버튼을 보여 줄지
-- 정하는 데 쓴다. 키 시각은 방 단위라 그 방 전체에서 모아 온다.
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
  if not public.bus_room_open() then
    return jsonb_build_object('status','closed');
  end if;

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
             case when k.in_at is not null then 'in'
                  when k.out_at is not null then 'out'
                  else 'pending' end as state,
             to_char(k.out_at at time zone 'Asia/Seoul', 'HH24:MI') as out_at,
             to_char(k.in_at  at time zone 'Asia/Seoul', 'HH24:MI') as in_at,
             public.bus_room_leader(public.bus_room_key(s.room_label, s.room_no))  as leader,
             public.bus_room_members(public.bus_room_key(s.room_label, s.room_no)) as members
        from public.bus_room_slots s
        cross join lateral (
          select max(x.key_out_at) as out_at, max(x.key_in_at) as in_at
            from public.bus_room_slots x
           where public.bus_room_key(x.room_label, x.room_no)
                 = public.bus_room_key(s.room_label, s.room_no)
        ) k
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

-- ---------------------------------------------------------------- 권한
revoke all on function public.bus_room_self(text, text, text) from public;
revoke all on function public.bus_room_info(text)             from public;

grant execute on function public.bus_room_self(text, text, text) to anon, authenticated, service_role;
grant execute on function public.bus_room_info(text)             to anon, authenticated, service_role;
