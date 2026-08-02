-- 숙소 방 안내도 On/Off 로 켜고 끈다.
--
-- 지금까지 참가자 화면에서 켜고 끌 수 있는 건 버스 편(가는 편 / 오는 편)뿐이었고
-- 숙소 방 안내는 늘 열려 있었다. 방 배정이 아직 확정되지 않았을 때 참가자가
-- 먼저 들여다보는 일을 막을 방법이 없었다.
--
--   bus_config.collecting_room = 'on' | 'off'
--
-- 기본값은 'on' 이라 지금까지와 똑같이 동작한다.
-- 참가자 화면은 켜져 있는 것만 보여 주고, 하나만 켜져 있으면 고르는 화면 없이
-- 바로 그 화면으로 들어간다. 그 판단에 쓰라고 bus_status 에 room_open 을 얹는다.

insert into public.bus_config(key, value) values ('collecting_room', 'on')
on conflict (key) do nothing;

-- ---------------------------------------------------------------- 헬퍼
create or replace function public.bus_room_open()
returns boolean
language sql
stable security definer
set search_path to 'public'
as $$
  select coalesce((select value from public.bus_config where key = 'collecting_room'), 'on') = 'on'
$$;

-- ---------------------------------------------------------------- 상태
create or replace function public.bus_status()
returns jsonb
language sql
stable security definer
set search_path to 'public'
as $$
  select jsonb_build_object(
    'open',      public.bus_leg_open('out') or public.bus_leg_open('back'),
    'out_open',  public.bus_leg_open('out'),
    'back_open', public.bus_leg_open('back'),
    'room_open', public.bus_room_open(),
    'legs',      (select coalesce(jsonb_agg(s.l order by s.ord), '[]'::jsonb)
                    from unnest(array['out','back']) with ordinality as s(l, ord)
                   where public.bus_leg_open(s.l)),
    'leg',       coalesce(public.bus_active_leg(null::text),
                          coalesce((select value from public.bus_config where key = 'active_leg'), 'out')),
    'title',     coalesce((select value from public.bus_config where key = 'event_title'), ''),
    'bus_no',    coalesce((select value from public.bus_config where key = 'bus_no'), ''),
    'place',     coalesce((select value from public.bus_config where key = 'boarding_place'), '')
  )
$$;

-- ---------------------------------------------------------------- 참가자
-- 꺼져 있으면 방 정보를 아예 내주지 않는다. 화면만 가리는 게 아니라
-- 서버에서 막아야 주소를 직접 두드려도 새지 않는다.
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

-- ---------------------------------------------------------------- 운영자
-- bus_room_admin 에 스위치를 더한다. list 는 지금 상태를 함께 돌려준다.
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
      'open', public.bus_room_open(),
      'unassigned', (select count(distinct p.phone) from public.bus_passengers p
                      where not exists (select 1 from public.bus_room_slots s
                                         where s.phone = p.phone)),
      'nights', jsonb_build_object(
        'n1', (select count(distinct phone) from public.bus_passengers where night1),
        'n2', (select count(distinct phone) from public.bus_passengers where night2)),
      'title', coalesce((select value from public.bus_config where key='event_title'), '')
    );

  elsif p_action = 'set_open' then
    insert into public.bus_config(key, value)
    values ('collecting_room',
            case when coalesce((p_payload->>'open')::boolean, false) then 'on' else 'off' end)
    on conflict (key) do update set value = excluded.value;
    return jsonb_build_object('status','ok', 'open', public.bus_room_open());

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

-- ---------------------------------------------------------------- 권한
revoke all on function public.bus_room_open()                   from public;
revoke all on function public.bus_status()                      from public;
revoke all on function public.bus_room_info(text)               from public;
revoke all on function public.bus_room_admin(text, text, jsonb) from public;

grant execute on function public.bus_room_open()                   to anon, authenticated, service_role;
grant execute on function public.bus_status()                      to anon, authenticated, service_role;
grant execute on function public.bus_room_info(text)               to anon, authenticated, service_role;
grant execute on function public.bus_room_admin(text, text, jsonb) to anon, authenticated, service_role;
