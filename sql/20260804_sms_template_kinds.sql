-- 저장해 둔 문자 메시지를 쓰임새별로 나눈다.
--
-- 지금까지는 탑승 현황 화면(admin.html)과 방키 수불 화면(rooms.html)이 저장해 둔
-- 메시지 한 통을 같이 썼다. 두 화면에서 보낼 내용이 서로 달라서, 고르는 목록에
-- 상관없는 문구가 섞여 나온다.
--
--   kind = 'bus'  — 탑승 관련 (admin.html)
--   kind = 'room' — 숙소 · 방키 관련 (rooms.html)
--
-- 이미 저장해 둔 메시지는 모두 'bus' 로 둔다. 어느 화면에서 저장했는지 알 길이
-- 없어서 그렇다. 숙소 쪽에서 쓰던 문구는 방키 화면에서 다시 저장하면 된다.

alter table public.bus_sms_templates
  add column if not exists kind text not null default 'bus';

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'bus_sms_templates_kind_check') then
    alter table public.bus_sms_templates
      add constraint bus_sms_templates_kind_check check (kind in ('bus','room'));
  end if;
end $$;

create index if not exists bus_sms_templates_kind_idx on public.bus_sms_templates (kind);

create or replace function public.bus_sms_admin(p_code text, p_action text,
                                                p_payload jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_code  text;
  v_id    bigint;
  v_title text := btrim(coalesce(p_payload->>'title', ''));
  v_body  text := coalesce(p_payload->>'body', '');
  -- kind 를 안 보내는 예전 화면은 예전처럼 'bus' 로 본다.
  v_kind  text := case when p_payload->>'kind' = 'room' then 'room' else 'bus' end;
begin
  select value into v_code from public.bus_config where key = 'admin_code';
  if v_code is null or p_code is null or p_code <> v_code then
    return jsonb_build_object('status', 'denied');
  end if;

  if p_action = 'list' then
    return jsonb_build_object(
      'status', 'ok',
      'kind', v_kind,
      'rows', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'title', title, 'body', body)
                                         order by title)
                          from public.bus_sms_templates
                         where kind = v_kind), '[]'::jsonb));

  elsif p_action = 'save' then
    if v_title = '' or btrim(v_body) = '' then
      return jsonb_build_object('status', 'invalid');
    end if;

    if (p_payload->>'id') is not null then
      update public.bus_sms_templates
         set title = v_title, body = v_body, kind = v_kind, updated_at = now()
       where id = (p_payload->>'id')::bigint
      returning id into v_id;
      if v_id is null then return jsonb_build_object('status', 'gone'); end if;
      return jsonb_build_object('status', 'ok', 'id', v_id);
    end if;

    insert into public.bus_sms_templates(title, body, kind)
    values (v_title, v_body, v_kind)
    returning id into v_id;
    return jsonb_build_object('status', 'ok', 'id', v_id);

  elsif p_action = 'del' then
    delete from public.bus_sms_templates where id = (p_payload->>'id')::bigint;
    return jsonb_build_object('status', 'ok');
  end if;

  return jsonb_build_object('status', 'unknown_action');
end;
$$;

revoke all on function public.bus_sms_admin(text, text, jsonb) from public;
grant execute on function public.bus_sms_admin(text, text, jsonb)
  to anon, authenticated, service_role;
