-- 방 목록·번호를 통째로 꺼내 볼 수 있는 헬퍼에서 anon 권한을 걷어낸다.
--
-- Supabase 는 public 스키마에 새로 만들어지는 함수에 anon/authenticated EXECUTE 를
-- 기본으로 붙인다(alter default privileges). 그래서 함수를 만들 때 `revoke all
-- ... from public` 만 해 두면 막힌 것처럼 보여도 실제로는 열려 있다.
-- (로컬 postgres 에서는 그 기본 권한이 없어 막힌 것처럼 보였다.)
--
-- 아래 셋은 공개 키(anon)만 있으면 이런 것들이 통째로 나온다.
--
--   bus_room_members(rkey)      — 방 이름만 알면 그 방 인원과 전화번호가 전부
--   bus_room_leader(rkey)       — 위와 같다
--   bus_same_person(note, name) — 이름·소속을 넣으면 그 사람 전화번호가 나온다
--
-- 셋 다 security definer 함수(bus_room_info · bus_room_admin · bus_admin ·
-- bus_people_admin) 안에서만 쓰이고 그 함수들은 소유자 권한으로 돌기 때문에,
-- 걷어내도 기능에는 영향이 없다.
--
-- 참가자에게 열어 두는 창구는 bus_room_info(p_phone) 하나뿐이다. 본인 번호를
-- 넣어야 하고, 본인이 든 방만 돌려준다.

revoke execute on function public.bus_room_members(text)      from anon, authenticated;
revoke execute on function public.bus_room_leader(text)       from anon, authenticated;
revoke execute on function public.bus_same_person(text, text) from anon, authenticated;
