# 버스 탑승 확인 (bus_checkin)

행사 버스의 탑승 여부를 참가자가 직접 확인하고, 인솔자가 실시간으로 현황을 보는
정적 페이지 3개 + Supabase RPC 로 이루어진 앱입니다.

| 파일 | 용도 |
| --- | --- |
| `index.html` | 참가자 화면 — 탑승 확인 / 탑승 취소 / 명단 요청 / 숙소 방 안내 |
| `admin.html` | 인솔자 화면 — 실시간 탑승 현황, 편별 취합 On/Off, 요청 승인, 문자 |
| `rooms.html` | 인솔자 화면 — 방 단위 키 수령·반납, 실제 호수 입력, 방별 문자 |
| `manage.html` | 관리 화면 — 명단·숙박 엑셀 업로드, 차량·탑승 위치, 안내 문구, 설정 |
| `sql/` | Supabase(Postgres) 함수 · 설정 마이그레이션 |

빌드 과정은 없습니다. 세 파일을 그대로 정적 호스팅에 올리면 됩니다.
(현재 Vercel 프로젝트 `sdu-bus-checkin` 으로 배포)

## 데이터

Supabase 프로젝트 `sudcoss-pd-exhibition` (`jqvbuqgpgmqyviqdkzvl`).

- `bus_passengers` — 편(`leg` = `out` 가는 편 / `back` 오는 편)별 명단과 `boarded_at`,
  숙박 컬럼(`room_label` 임시배정명 · `room_no` 실제 호수 · `is_leader` · `key_out_at` · `key_in_at`).
  숙박 정보는 편과 무관하므로 전화번호 기준으로 양쪽 편 행에 같이 반영된다.
- `bus_requests` — 참가자가 보낸 명단 추가/번호 수정 요청
- `bus_groups` — 소속·팀명 선택지
- `bus_config` — 키/값 설정

### bus_config 키

| 키 | 뜻 |
| --- | --- |
| `admin_code` | 운영 코드 |
| `active_leg` | 운영자가 마지막으로 보던 편 (기본값 용도) |
| `collecting_out` / `collecting_back` | **편별 취합 On/Off** — 참가자 화면에 노출할 편 |
| `collecting` | 예전 단일 스위치. 두 편 중 하나라도 On 이면 `on` 으로 유지되는 호환용 값 |
| `event_title`, `bus_no`, `boarding_place` | 화면에 표시되는 행사 정보 |

### RPC

익명(anon) 키로 호출합니다.

- `bus_status()` — `out_open` / `back_open` / `legs`(켜져 있는 편 목록) / 행사 정보
- `bus_check_in(p_phone, p_leg default null)` — 탑승 확인
- `bus_check_out(p_phone, p_leg default null)` — 탑승 확인 취소
- `bus_request_add(p_name, p_phone, p_note default null, p_leg default null)`
- `bus_request_status(p_phone, p_leg default null)`
- `bus_group_options()`
- `bus_room_info(p_phone)` — 본인 방 정보만 반환(호수·방장·같은 방 명단·안내 문구). 전체 배정표는 노출하지 않음
- `bus_admin(p_code, p_action, p_payload)` — 운영 코드로 보호되는 모든 운영 동작. `upload` 는 숙박 열이 있으면 함께 반영
- `bus_room_admin(p_code, p_action, p_payload)` — 방 목록 / 키 수령·반납·취소 / 호수 입력 / 안내 문구 저장
- `bus_set_info(p_code, p_bus, p_place)`

`p_leg` 를 넘기지 않으면 켜져 있는 편 중 하나를 알아서 고르므로, 예전에 배포된
화면도 그대로 동작합니다.

## 편별 취합 On/Off

`admin.html` 의 탭은 **아래 명단을 어느 편으로 볼지**만 고릅니다.
참가자 화면에 무엇이 보일지는 그 아래 두 개의 On/Off 스위치가 정합니다.

- 두 편 모두 On → 참가자 화면 위쪽에 가는 편 / 오는 편 선택 버튼이 나타납니다.
- 한 편만 On → 그 편으로 바로 진행합니다.
- 두 편 모두 Off → 참가자 화면이 "지금은 확인 전입니다" 로 잠깁니다.

## 마이그레이션

`sql/` 안의 파일은 Supabase 에 순서대로 적용된 델타입니다. 이미 존재하는
`bus_norm_phone` 같은 함수와 테이블은 전제로 두고 있습니다.
