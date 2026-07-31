-- 가는 편 / 오는 편 취합을 각각 On/Off 로 켜고 끄고,
-- 참가자가 스스로 탑승 확인을 취소할 수 있게 한다.
--
-- 예전에 배포된 화면이 그대로 도는 상태에서도 안전하도록,
-- 새 인자 p_leg 에는 기본값을 준다. 오버로드를 만들지 않고 함수 하나로 유지해
-- PostgREST 가 인자 이름으로 함수를 고르다 헷갈릴 일을 없앤다.
--   예전 화면: {p_phone}                      -> p_leg = null -> 켜져 있는 편을 알아서 고름
--   새   화면: {p_phone, p_leg}               -> 참가자가 고른 편

-- ---------------------------------------------------------------- 설정값
-- 지금까지 쓰던 collecting 값을 두 편에 그대로 물려준다.
insert into public.bus_config(key, value)
values ('collecting_out', coalesce((select value from public.bus_config where key = 'collecting'), 'on'))
on conflict (key) do nothing;

insert into public.bus_config(key, value)
values ('collecting_back', coalesce((select value from public.bus_config where key = 'collecting'), 'on'))
on conflict (key) do nothing;

-- ---------------------------------------------------------------- 헬퍼
create or replace function public.bus_leg_open(p_leg text)
returns boolean
language sql
stable security definer
set search_path to 'public'
as $$
  select coalesce(
    (select value from public.bus_config
      where key = 'collecting_' || (case when p_leg = 'back' then 'back' else 'out' end)),
    'on') = 'on'
$$;

-- 참가자가 고른 편이 켜져 있으면 그 편, 안 고르면 켜져 있는 편 중 하나.
-- 켜진 편이 없으면 null.
create or replace function public.bus_active_leg(p_leg text)
returns text
language sql
stable security definer
set search_path to 'public'
as $$
  select case
    when p_leg in ('out','back')
      then (case when public.bus_leg_open(p_leg) then p_leg else null end)
    else (
      select s.l
        from unnest(array[
               coalesce((select value from public.bus_config where key = 'active_leg'), 'out'),
               'out', 'back'
             ]) with ordinality as s(l, ord)
       where s.l in ('out','back') and public.bus_leg_open(s.l)
       order by s.ord
       limit 1
    )
  end
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

-- ---------------------------------------------------------------- 탑승 확인
drop function if exists public.bus_check_in(text);
drop function if exists public.bus_request_status(text);
drop function if exists public.bus_request_add(text, text, text);

create or replace function public.bus_check_in(p_phone text, p_leg text default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_phone text := public.bus_norm_phone(p_phone);
  v_leg   text := public.bus_active_leg(p_leg);
  v_row   public.bus_passengers%rowtype;
begin
  if v_leg is null then
    return jsonb_build_object('status', 'closed');
  end if;

  if length(v_phone) < 8 then
    return jsonb_build_object('status', 'invalid', 'leg', v_leg);
  end if;

  select * into v_row from public.bus_passengers where leg = v_leg and phone = v_phone;

  if not found then
    return jsonb_build_object('status', 'not_found', 'leg', v_leg);
  end if;

  if v_row.boarded_at is not null then
    return jsonb_build_object('status', 'already', 'leg', v_leg, 'name', v_row.name,
      'at', to_char(v_row.boarded_at at time zone 'Asia/Seoul', 'HH24:MI'));
  end if;

  update public.bus_passengers set boarded_at = now() where id = v_row.id returning * into v_row;

  return jsonb_build_object('status', 'ok', 'leg', v_leg, 'name', v_row.name,
    'at', to_char(v_row.boarded_at at time zone 'Asia/Seoul', 'HH24:MI'));
end;
$$;

-- ---------------------------------------------------------------- 탑승 취소
create or replace function public.bus_check_out(p_phone text, p_leg text default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_phone text := public.bus_norm_phone(p_phone);
  v_leg   text := public.bus_active_leg(p_leg);
  v_row   public.bus_passengers%rowtype;
begin
  if v_leg is null then
    return jsonb_build_object('status', 'closed');
  end if;

  if length(v_phone) < 8 then
    return jsonb_build_object('status', 'invalid', 'leg', v_leg);
  end if;

  select * into v_row from public.bus_passengers where leg = v_leg and phone = v_phone;

  if not found then
    return jsonb_build_object('status', 'not_found', 'leg', v_leg);
  end if;

  if v_row.boarded_at is null then
    return jsonb_build_object('status', 'not_boarded', 'leg', v_leg, 'name', v_row.name,
      'at', to_char(now() at time zone 'Asia/Seoul', 'HH24:MI'));
  end if;

  update public.bus_passengers set boarded_at = null where id = v_row.id;

  return jsonb_build_object('status', 'ok', 'leg', v_leg, 'name', v_row.name,
    'at', to_char(now() at time zone 'Asia/Seoul', 'HH24:MI'));
end;
$$;

-- ---------------------------------------------------------------- 명단 요청
create or replace function public.bus_request_add(p_name text, p_phone text,
                                                  p_note text default null,
                                                  p_leg  text default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_phone  text := public.bus_norm_phone(p_phone);
  v_name   text := btrim(coalesce(p_name, ''));
  v_note   text := nullif(btrim(coalesce(p_note, '')), '');
  v_leg    text;
  v_cnt    int;
  v_target public.bus_passengers%rowtype;
  v_kind   text := 'add';
begin
  v_leg := case
             when p_leg in ('out','back') then p_leg
             else coalesce(public.bus_active_leg(null::text),
                           coalesce((select value from public.bus_config where key = 'active_leg'), 'out'))
           end;

  if v_name = '' or length(v_phone) < 10 then
    return jsonb_build_object('status', 'invalid');
  end if;

  if exists (select 1 from public.bus_passengers where leg = v_leg and phone = v_phone) then
    return jsonb_build_object('status', 'exists');
  end if;

  select count(*) into v_cnt from public.bus_requests where status = 'pending';
  if v_cnt > 300 then
    return jsonb_build_object('status', 'busy');
  end if;

  if exists (select 1 from public.bus_requests
              where phone = v_phone and leg = v_leg and status = 'pending') then
    return jsonb_build_object('status', 'dup');
  end if;

  -- 이름 + 소속이 같은 사람이 이미 명단에 있으면 번호 수정 요청
  select * into v_target
    from public.bus_passengers
   where leg = v_leg
     and btrim(name) = v_name
     and coalesce(nullif(btrim(note), ''), '') = coalesce(v_note, '')
   limit 1;

  if found then
    v_kind := 'fix';
  end if;

  insert into public.bus_requests(name, phone, note, leg, kind, target_id, old_phone)
  values (v_name, v_phone, v_note, v_leg, v_kind,
          case when v_kind = 'fix' then v_target.id else null end,
          case when v_kind = 'fix' then v_target.phone else null end);

  return jsonb_build_object('status', 'ok', 'kind', v_kind, 'leg', v_leg);
end;
$$;

create or replace function public.bus_request_status(p_phone text, p_leg text default null)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $$
declare
  v_phone text := public.bus_norm_phone(p_phone);
  v_leg   text;
begin
  v_leg := case
             when p_leg in ('out','back') then p_leg
             else coalesce(public.bus_active_leg(null::text),
                           coalesce((select value from public.bus_config where key = 'active_leg'), 'out'))
           end;

  if length(v_phone) < 10 then
    return jsonb_build_object('state', 'none');
  end if;

  if exists (select 1 from public.bus_passengers where leg = v_leg and phone = v_phone) then
    return jsonb_build_object('state', 'approved');
  end if;

  if exists (select 1 from public.bus_requests
              where phone = v_phone and leg = v_leg and status = 'pending') then
    return jsonb_build_object('state', 'pending');
  end if;

  if exists (select 1 from public.bus_requests
              where phone = v_phone and leg = v_leg and status = 'rejected') then
    return jsonb_build_object('state', 'rejected');
  end if;

  return jsonb_build_object('state', 'none');
end;
$$;

-- ---------------------------------------------------------------- 운영자
create or replace function public.bus_admin(p_code text, p_action text, p_payload jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_code text;
  v_leg  text;
  v_row  jsonb;
  v_rows jsonb;
  v_tot  jsonb;
  v_req  public.bus_requests%rowtype;
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
      insert into public.bus_passengers(name, phone, note, leg)
      values (btrim(v_row->>'name'),
              public.bus_norm_phone(v_row->>'phone'),
              nullif(btrim(coalesce(v_row->>'note','')), ''),
              v_leg)
      on conflict (leg, phone) do update
        set name = excluded.name, note = excluded.note;
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

  -- 취합 On/Off 는 payload 의 leg 가 가리키는 편에만 적용된다.
  elsif p_action = 'set_collecting' then
    insert into public.bus_config(key, value)
    values ('collecting_' || v_leg,
            case when coalesce((p_payload->>'open')::boolean, false) then 'on' else 'off' end)
    on conflict (key) do update set value = excluded.value;

    -- 예전 화면이 읽는 키도 맞춰 둔다.
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
revoke all on function public.bus_leg_open(text) from public;
revoke all on function public.bus_active_leg(text) from public;
revoke all on function public.bus_check_in(text, text) from public;
revoke all on function public.bus_check_out(text, text) from public;
revoke all on function public.bus_request_add(text, text, text, text) from public;
revoke all on function public.bus_request_status(text, text) from public;

grant execute on function public.bus_leg_open(text)                        to anon, authenticated, service_role;
grant execute on function public.bus_active_leg(text)                      to anon, authenticated, service_role;
grant execute on function public.bus_check_in(text, text)                  to anon, authenticated, service_role;
grant execute on function public.bus_check_out(text, text)                 to anon, authenticated, service_role;
grant execute on function public.bus_request_add(text, text, text, text)   to anon, authenticated, service_role;
grant execute on function public.bus_request_status(text, text)            to anon, authenticated, service_role;
