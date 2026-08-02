-- 방 목록을 소속별로도 볼 수 있게, 그리고 호수를 표에서 한꺼번에 넣을 수 있게.
--
-- 1) bus_room_members 에 소속(note)을 얹는다. 방을 소속별로 묶어 보려면 방에 든
--    사람의 소속을 알아야 한다. 소속은 "강원대학교 딸깍" 처럼 대학과 팀명을
--    합친 한 값이다(업로드할 때 합쳐서 넣는다).
--
-- 2) bus_room_nos — 호수를 방마다 하나씩 누르지 않고 표에서 쭉 입력한 뒤 한 번에
--    저장한다. bus_room_admin 이 이미 길어서 함수를 따로 뒀고, 보호 방식은 같다.

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
           'note',      coalesce(m.note, ''),
           'night1',    m.night1,
           'night2',    m.night2)
           order by m.is_leader desc, m.name), '[]'::jsonb)
    from (
      select s.phone,
             bool_or(s.is_leader) as is_leader,
             max(p.name)          as name,
             max(p.gender)        as gender,
             max(p.note)          as note,
             bool_or(p.night1)    as night1,
             bool_or(p.night2)    as night2
        from public.bus_room_slots s
        join public.bus_passengers p on p.phone = s.phone
       where public.bus_room_key(s.room_label, s.room_no) = p_rkey
       group by s.phone
    ) m
$$;

revoke execute on function public.bus_room_members(text) from anon, authenticated;

-- ---------------------------------------------------------------- 호수 일괄 저장
-- p_rows = [{"room":"트리플1","no":"1004호"}, ...]
-- no 가 빈 값이면 그 방의 호수를 지운다. 방 이름(room)은 지금 쓰는 방 식별자다.
create or replace function public.bus_room_nos(p_code text, p_rows jsonb default '[]'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_code text;
  v_row  jsonb;
  v_room text;
  v_no   text;
  v_n    int := 0;
begin
  select value into v_code from public.bus_config where key = 'admin_code';
  if v_code is null or p_code is null or p_code <> v_code then
    return jsonb_build_object('status', 'denied');
  end if;

  for v_row in select * from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) loop
    v_room := btrim(coalesce(v_row->>'room', ''));
    continue when v_room = '';
    v_no := nullif(btrim(coalesce(v_row->>'no', '')), '');

    -- 임시배정명이 없는 방(식별자가 곧 호수)에서 호수를 지우면 방이 사라진다.
    -- 그런 방은 건드리지 않는다.
    update public.bus_room_slots
       set room_no = v_no
     where public.bus_room_key(room_label, room_no) = v_room
       and (v_no is not null
            or nullif(btrim(coalesce(room_label,'')), '') is not null);
    v_n := v_n + 1;
  end loop;

  return jsonb_build_object('status', 'ok', 'saved', v_n);
end;
$$;

revoke all on function public.bus_room_nos(text, jsonb) from public;
grant execute on function public.bus_room_nos(text, jsonb) to anon, authenticated, service_role;
