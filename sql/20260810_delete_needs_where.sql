-- "전체 삭제" 와 "전체 덮어쓰기" 가 먹통이던 진짜 원인.
--
-- 참가자·운영자 화면은 PostgREST(anon 키)를 거쳐 함수를 부른다. Supabase 는 그
-- 연결에 pg_safeupdate 를 걸어 두어서, WHERE 없는 DELETE 를 실행하면
--
--   21000 / DELETE requires a WHERE clause
--
-- 를 던지고 통째로 막는다. security definer 라도 소용없다 — 세션에 걸린 안전장치라
-- 함수 안에서 도는 문장에도 그대로 적용된다.
--
-- 그래서 아래 두 곳이 조용히 실패하고 있었다.
--   bus_admin  purge (scope = all)          — 전체 삭제
--   bus_admin  upload_sheet (mode = replace) — 전체 덮어쓰기
--
-- 로컬 postgres 와 Supabase SQL 편집기에는 이 안전장치가 없어서 잘 도는 것처럼
-- 보였다. 화면에 오류를 적어 주기 시작하면서 드러났다.
--
-- 고치는 방법은 WHERE 를 붙여 주는 것뿐이다. 기본키는 null 이 될 수 없으므로
-- `where id is not null` 은 전부 지우면서도 안전장치를 만족한다.

do $mig$
declare
  src text;
  old text := $snip$      delete from public.bus_room_slots;
      delete from public.bus_passengers;
      delete from public.bus_requests;$snip$;
  new text := $snip$      -- WHERE 를 붙여야 한다. pg_safeupdate 가 WHERE 없는 DELETE 를 막는다.
      delete from public.bus_room_slots where id is not null;
      delete from public.bus_passengers where id is not null;
      delete from public.bus_requests   where id is not null;$snip$;
  n int;
begin
  select pg_get_functiondef(p.oid) into src
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and p.proname = 'bus_admin';
  if src is null then raise exception 'bus_admin 을 찾지 못했습니다'; end if;

  -- 두 군데(전체 덮어쓰기 · 전체 삭제) 모두 있어야 한다.
  n := (length(src) - length(replace(src, old, ''))) / length(old);
  if n <> 2 then
    raise exception 'WHERE 없는 DELETE 를 2군데 기대했는데 %군데 찾았습니다', n;
  end if;

  execute replace(src, old, new);
end
$mig$;

revoke all on function public.bus_admin(text, text, jsonb) from public;
grant execute on function public.bus_admin(text, text, jsonb) to anon, authenticated, service_role;
