# Load Generator 로컬 실행 가이드

## 근본 목적
`migration/database/load-generator` 기반 부하 도구를 팀원이 로컬에서 동일한 방식으로 빠르게 재현하게 해서, 마이그레이션 전 점검/원인 추적 시간을 줄인다.

## 비목적
이 문서는 K6 시나리오 로직 수정이나 API 동작 변경을 다루지 않는다. 실행 방법과 운영 팁만 정리한다.

## 1. 위치
- 스크립트: `migration/database/load-generator/k6`
- 주요 파일:
  - `warmup.js` (read-only 워밍업)
  - `load-test.js` (혼합 HTTP/WS 부하)
  - `cutover-monitor.js` (컷오버 모니터링)

## 2. 사전 준비
- Docker 설치
- 외부 API 대상에 대한 네트워크 접근 가능
- 기본 작업 디렉터리:

```bash
cd /Users/cho/IdeaProjects/6-team-team6-cloud
```

## 3. 공통 환경변수
- `TARGET_URL`: 요청 대상 베이스 URL
  - 예시: `https://api.dev.billages.com`
- `WS_URL`: WebSocket URL (생략 시 `TARGET_URL`에서 자동 유도)
  - 예시: `wss://api.dev.billages.com/ws`
- `GROUP_ID`: 그룹 ID (기본 1)

대상 변경은 `-e TARGET_URL=...`만 바꿔서 처리한다.

## 4. 방법 A: Warmup (read-only)
가벼운 사전 예열 용도다. 쓰기 요청(POST/PUT/PATCH/DELETE)을 보내지 않는다.

```bash
docker run --rm --name k6-warmup-local \
  -v "/Users/cho/IdeaProjects/6-team-team6-cloud/migration/database/load-generator/k6:/scripts" \
  -e TARGET_URL="https://api.dev.billages.com" \
  -e GROUP_ID="1" \
  -e WARMUP_RPS="3" \
  -e WARMUP_DURATION="1m" \
  -e WARMUP_PRE_ALLOCATED_VUS="5" \
  -e WARMUP_MAX_VUS="20" \
  -e K6_INSECURE_SKIP_TLS_VERIFY="true" \
  grafana/k6:0.49.0 run /scripts/warmup.js
```

## 5. 방법 B: Mixed Load Test
HTTP 혼합 트래픽(옵션으로 WS 포함) 실행용이다.

```bash
docker run --rm --name k6-load-local \
  -v "/Users/cho/IdeaProjects/6-team-team6-cloud/migration/database/load-generator/k6:/scripts" \
  -e TARGET_URL="https://api.dev.billages.com" \
  -e GROUP_ID="1" \
  -e ENABLE_WS="false" \
  -e STRICT_THRESHOLDS="false" \
  -e HTTP_RPS_MIN="3" \
  -e HTTP_RPS_MID="3" \
  -e HTTP_RPS_MAX="3" \
  -e HTTP_STAGE_1="20s" \
  -e HTTP_STAGE_2="20s" \
  -e HTTP_STAGE_3="20s" \
  -e HTTP_PRE_ALLOCATED_VUS="20" \
  -e HTTP_MAX_VUS="50" \
  -e K6_INSECURE_SKIP_TLS_VERIFY="true" \
  grafana/k6:0.49.0 run /scripts/load-test.js
```

참고:
- 현재 dev 환경에서는 신규 가입 계정이 바로 게시글 생성 권한/그룹 멤버십을 가지지 않아 seed 단계가 실패할 수 있다.
- 이 경우 `SKIP_SETUP=true` + `PRESET_TOKEN_LIST`(사전 발급 토큰 목록)으로 실행하는 방식을 사용한다.

## 6. 방법 C: Cutover Monitor
컷오버 구간 관측 지표(오류율/다운타임/지연시간)를 확인한다.

```bash
docker run --rm --name k6-cutover-local \
  -v "/Users/cho/IdeaProjects/6-team-team6-cloud/migration/database/load-generator/k6:/scripts" \
  -e TARGET_URL="https://api.dev.billages.com" \
  -e GROUP_ID="1" \
  -e CUTOVER_READ_PROBE_MODE="health" \
  -e CUTOVER_INCLUDE_WRITE_PROBE="false" \
  -e CUTOVER_RPS="3" \
  -e CUTOVER_DURATION="30s" \
  -e CUTOVER_DOWNTIME_PROBE_INTERVAL_MS="1000" \
  -e CUTOVER_MAX_ERROR_RATE="0.10" \
  -e CUTOVER_P95_MS="2000" \
  -e K6_INSECURE_SKIP_TLS_VERIFY="true" \
  grafana/k6:0.49.0 run /scripts/cutover-monitor.js
```

## 7. 실행 검증 (2026-02-27)
대상: `https://api.dev.billages.com`  
시나리오: `cutover-monitor.js` (`CUTOVER_READ_PROBE_MODE=health`, `CUTOVER_RPS=3`)

- 종료 코드: `0`
- `http_reqs`: `123`
- `http_req_failed`: `0.00%` (`0/123`)
- `cutover_total_error_rate`: `0.00%` (`0/91`)
- Threshold:
  - `cutover_response_time p95<=2000ms`: PASS (`37.17ms`)
  - `cutover_total_error_rate rate<=0.10`: PASS
  - `cutover_unexpected_write_failure_rate`: PASS
  - `cutover_unplanned_downtime_total_ms`: PASS (`0`)
  - `cutover_write_block_rate`: PASS

## 8. 트러블슈팅
- `Seed post creation failed`:
  - 원인: 계정 권한/멤버십 부족으로 POST seed 실패
  - 대응: `SKIP_SETUP=true`, `PRESET_TOKEN_LIST` 또는 `PRESET_USERS_JSON` 사용
- `401 AUTH02` 다량 발생:
  - 원인: 토큰 미주입 또는 인증 실패
  - 대응: `AUTH_TOKEN`/`WARMUP_AUTH_TOKEN`/`CUTOVER_AUTH_TOKEN` 확인
- WS 핸드셰이크 실패:
  - `WS_URL` 확인, 필요 시 `WS_HANDSHAKE_AUTH_HEADER=true` 사용
