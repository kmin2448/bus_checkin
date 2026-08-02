-- 객실을 보여 주는 순서를 정한다.
--
-- 방 이름은 "더블1", "더블온돌8", "트리플5" 처럼 <구분><번호> 로 되어 있다.
-- 앞의 같은 이름이 곧 방 구분이므로, 구분을 나열한 순서대로 보여 주고 같은
-- 구분 안에서는 번호 순으로 놓는다.
--
-- 주의: "더블온돌1" 은 "더블" 로도 시작한다. 그래서 구분을 고를 때는
-- **가장 긴 것이 이긴다**. 안 그러면 더블온돌이 전부 더블 무리에 섞인다.
-- 이 판단은 화면(admin.html · manage.html)에서 하고, 여기서는 순서 문자열만
-- 넣고 뺀다. bus_room_admin 이 이미 길어서 통째로 다시 정의하지 않으려는 것이다.
--
--   bus_config.room_order = '더블,트윈,트리플,더블온돌'
--
-- 목록에 없는 구분은 맨 뒤로 가고, 그 안에서는 이름 순이다.

insert into public.bus_config(key, value) values ('room_order', '더블,트윈,트리플,더블온돌')
on conflict (key) do nothing;

-- p_order 를 안 주면 지금 값을 돌려주고, 주면 저장한 뒤 저장된 값을 돌려준다.
create or replace function public.bus_room_order(p_code text, p_order text default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_code text;
  v_val  text;
begin
  select value into v_code from public.bus_config where key = 'admin_code';
  if v_code is null or p_code is null or p_code <> v_code then
    return jsonb_build_object('status', 'denied');
  end if;

  if p_order is not null then
    -- 빈 칸과 중복을 걷어내고 쉼표로 잇는다.
    select string_agg(p, ',' order by i)
      into v_val
      from (
        select distinct on (btrim(p)) btrim(p) as p, i
          from unnest(string_to_array(p_order, ',')) with ordinality as t(p, i)
         where btrim(p) <> ''
         order by btrim(p), i
      ) s;
    v_val := coalesce(v_val, '');

    insert into public.bus_config(key, value) values ('room_order', v_val)
    on conflict (key) do update set value = excluded.value;
  end if;

  select value into v_val from public.bus_config where key = 'room_order';
  return jsonb_build_object('status', 'ok', 'order', coalesce(v_val, ''));
end;
$$;

revoke all on function public.bus_room_order(text, text) from public;
grant execute on function public.bus_room_order(text, text) to anon, authenticated, service_role;
