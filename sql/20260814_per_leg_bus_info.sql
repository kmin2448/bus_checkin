-- 차량 번호와 탑승 위치를 가는 편 / 오는 편 따로 저장한다.
--
-- 지금까지 bus_no · boarding_place 한 쌍을 두 편이 같이 썼다. 실제로는
-- 갈 때와 올 때 차량도 타는 곳도 다르므로, 개별 설정에서 편을 고른 채로
-- 저장하면 그 편에만 적용되어야 한다.
--
--   bus_config.bus_no_out / bus_no_back
--   bus_config.boarding_place_out / boarding_place_back
--
-- 참가자 화면 호환: bus_status() 의 bus_no · place 는 그대로 두되, 지금
-- 열려 있는 편(leg)의 값을 내려준다. 참가자는 열린 편 하나를 따라가므로
-- 예전에 배포된 index.html 도 자동으로 맞는 편의 정보를 보여 준다.
-- 두 편 값이 다 필요한 새 화면을 위해 info.out / info.back 을 얹는다.
--
-- bus_set_info 호환: p_leg 를 안 주면(예전 관리 화면) 두 편에 같이 쓴다.
-- 오버로드를 만들지 않으려고 예전 3인자 함수는 지운다 — PostgREST 가 인자
-- 이름으로 함수를 고르다 헷갈리는 일을 막는다.

-- ---------------------------------------------------------------- 설정값
-- 지금까지 쓰던 공용 값을 두 편에 그대로 물려준다.
insert into public.bus_config(key, value)
select 'bus_no_' || l, coalesce((select value from public.bus_config where key = 'bus_no'), '')
  from unnest(array['out','back']) as l
on conflict (key) do nothing;

insert into public.bus_config(key, value)
select 'boarding_place_' || l, coalesce((select value from public.bus_config where key = 'boarding_place'), '')
  from unnest(array['out','back']) as l
on conflict (key) do nothing;

-- ---------------------------------------------------------------- 저장
drop function if exists public.bus_set_info(text, text, text);

create or replace function public.bus_set_info(p_code text, p_bus text, p_place text,
                                               p_leg text default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_code text;
  l      text;
begin
  select value into v_code from public.bus_config where key = 'admin_code';
  if v_code is null or p_code is null or p_code <> v_code then
    return jsonb_build_object('status', 'denied');
  end if;

  -- 편을 고르면 그 편에만, 안 고르면(예전 화면) 두 편 모두.
  foreach l in array (case when p_leg in ('out','back')
                           then array[p_leg] else array['out','back'] end) loop
    insert into public.bus_config(key, value)
    values ('bus_no_' || l, btrim(coalesce(p_bus, '')))
    on conflict (key) do update set value = excluded.value;

    insert into public.bus_config(key, value)
    values ('boarding_place_' || l, btrim(coalesce(p_place, '')))
    on conflict (key) do update set value = excluded.value;
  end loop;

  return jsonb_build_object('status', 'ok');
end;
$$;

-- ---------------------------------------------------------------- 상태
-- bus_no · place 는 지금 열려 있는 편의 값(예전 화면 호환),
-- info 는 두 편의 값 전부(관리 화면과 새 참가자 화면용).
create or replace function public.bus_status()
returns jsonb
language sql
stable security definer
set search_path to 'public'
as $$
  with l as (
    select coalesce(public.bus_active_leg(null::text),
                    coalesce((select value from public.bus_config where key = 'active_leg'), 'out')) as leg
  )
  select jsonb_build_object(
    'open',      public.bus_leg_open('out') or public.bus_leg_open('back'),
    'out_open',  public.bus_leg_open('out'),
    'back_open', public.bus_leg_open('back'),
    'room_open', public.bus_room_open(),
    'legs',      (select coalesce(jsonb_agg(s.l order by s.ord), '[]'::jsonb)
                    from unnest(array['out','back']) with ordinality as s(l, ord)
                   where public.bus_leg_open(s.l)),
    'leg',       l.leg,
    'title',     coalesce((select value from public.bus_config where key = 'event_title'), ''),
    'bus_no',    coalesce((select value from public.bus_config where key = 'bus_no_' || l.leg), ''),
    'place',     coalesce((select value from public.bus_config where key = 'boarding_place_' || l.leg), ''),
    'info', jsonb_build_object(
      'out',  jsonb_build_object(
        'bus_no', coalesce((select value from public.bus_config where key = 'bus_no_out'), ''),
        'place',  coalesce((select value from public.bus_config where key = 'boarding_place_out'), '')),
      'back', jsonb_build_object(
        'bus_no', coalesce((select value from public.bus_config where key = 'bus_no_back'), ''),
        'place',  coalesce((select value from public.bus_config where key = 'boarding_place_back'), '')))
  )
  from l
$$;

-- ---------------------------------------------------------------- 권한
revoke all on function public.bus_set_info(text, text, text, text) from public;
revoke all on function public.bus_status() from public;

grant execute on function public.bus_set_info(text, text, text, text) to anon, authenticated, service_role;
grant execute on function public.bus_status()                         to anon, authenticated, service_role;
