# 인프라 리허설 실패 유발 로그 정리 (2026-03-02)

## 근본 목적
`migration-plan.md`의 전환 실행을 실제 수치로 재현·분해하여, 컷오버/롤백 판정을 반복 가능한 기준으로 고정한다.

## 비목적
서비스 기능 개선, 비용 최적화, 장기 운영 정책 수립은 범위 밖이며, 본 문서는 리허설 실행 데이터와 판정 기준 정합성 검증에 집중한다.

## 1. 목적
이 문서는 `migration/infra/docs/migration-plan.md`의 전환 실행 흐름(Phase 0~4, 섹션 11~14)을 기준으로,
- 베이스라인 정상성 확보
- 전환 중 동작 비교(일반 케이스)
- 실패 유발 실험
- 대응/롤백 판단 근거

를 한 번에 확인할 수 있도록 정리한 운영용 기록이다.

핵심 질문:
1. 새 리허설 스택이 기존 스택과 동일한 DB 기반에서 동작하는가?
2. 베이스라인 대비 전환 구간 지표가 허용 기준 이내인가?
3. 어떤 장애가 발생했을 때 실제로 어느 레이어에서 복원할 수 있는가?

---

## 2. 계획서 매핑 (실행 기준)

- Phase 0(사전 점검): ASG/ALB/RDS/NGINX 상태, 모니터링 경로, 헬스체크 선검증
- Phase 2(Upstream 카나리): 가중치 기반 트래픽 비율 전환
- Phase 3/4(최종 구조 고정): ALB 기반 TG 가중치 표준으로 전환 스위치 이전
- 섹션 11 모니터링 기준: 에러율/지연/5xx/헬스 상태 및 연속 장애 판단

현재 수행 범위는 **Phase 0 + Phase 2(일반 케이스 및 실패 유발 1차)**
입니다.

---

## 3. 실험 대상 환경

### 3.1 공통 타겟
- 타겟 ALB: `billage-rehearsal-rehearsal-alb-56308433.ap-northeast-2.elb.amazonaws.com`
- ASG: `billage-rehearsal-rehearsal-be-asg`
- Nginx 스위치 레이어(소스): `10.0.1.123`
- RDS(동일 라인): `billage-rehearsal-mysql.cpigi2qskxj3.ap-northeast-2.rds.amazonaws.com:3306`

### 3.2 베이스 테스트 전 검증
- `localhost:8080` 헬스 응답 정상(legacy)
- ALB 타깃 상태 정상 등록 확인
- RDS 연결 가용성 확인
- 새 스택 및 소스 스택이 동일 RDS를 바라보는 구성으로 확인

### 3.3 공통 관측/기록 항목
- `cutover-monitor.js` 실행 결과:
  - `cutover_total_error_rate`
  - `cutover_read_error_rate`
  - `http_req_failed`
  - `cutover_unplanned_downtime_total_ms`
  - `cutover_response_time` (p95)
- 타임라인 이벤트: 502/다운 발생 구간 및 복구 구간 기록
- ASG/Target Group 상태 전이 (inservice/initial/draining)

### 3.4 합격 판정 기준(계획서 기준 적용)
- `전환 구간 에러율` 실패 임계치: **0.1% 초과 시 롤백 후보**
- downtime: **가능한 한 0ms에 가까울수록** 양호  
- 5xx는 누적/지속 발생 시 즉시 단계 정지 판단

---

## 4. 시나리오 A — 일반 케이스(베이스라인) 실행

### 4.1 목적
컷오버 판단의 기준선을 확보하기 위한 정상 부하 기준.

### 4.2 절차
1. 소스 Nginx는 legacy 100%로 유지
2. k6 `cutover-monitor.js` 실행
3. 파라미터:
   - `CUTOVER_RPS=8`
   - `CUTOVER_DURATION=2m`
   - `CUTOVER_TARGET_URL='http://test.billages.com/api'`
   - `CUTOVER_READ_PROBE_MODE='health'`
   - `CUTOVER_INCLUDE_WRITE_PROBE='false'`
4. 결과를 실시간 수집 후 기준선 산출

### 4.3 결과(수집값)
- 총 실행: 약 120초
- `http_reqs`: 1195
- `iterations`: 1193
- `checks`: **100.00%** (961/961)
- `cutover_read_error_rate`: **0.00%**
- `cutover_total_error_rate`: **0.00%**
- `cutover_unplanned_downtime_total_ms`: **0ms**
- `http_req_failed`: **0.00%**
- `cutover_response_time p95`: **18.17ms**
- 평균 응답은 1~2ms 대에서 10~20ms대 수준으로, 8 rps 구간에서 안정적

### 4.4 결론
- 베이스라인 정상 동작(임계치 초과 없음)
- 일반 케이스에서의 “문제 없는 상태”가 확보됨
- 다음 시나리오(컷오버 혼합 트래픽) 대비 비교군으로 적합

### 4.5 보정 재실행(공통 probe 정합성)
- 같은 베이스라인 조건에서 `CUTOVER_READ_PROBE_SKIP_AUTH=true`로 `health` probe를 실행.
- `CUTOVER_RPS=8`, `CUTOVER_DURATION=2m`, `CUTOVER_INCLUDE_WRITE_PROBE=false`.
- 결과: `checks 100.00%`, `cutover_read_error_rate 0.00%`, `cutover_total_error_rate 0.00%`, `http_req_failed 0.00%`, `cutover_unplanned_downtime_total_ms 0`, `p95=16.12ms`.
- 동일 설정으로 9:1 혼입에서도 `cutover_total_error_rate 0.00%`로 통과.

---

## 5. 시나리오 B — 전환 시작 혼입(일반 전환 흐름 재현)

### 5.1 목적
Phase 2 카나리의 기본 동작을 검증하고, 전환 구간에서의 관측/분류 정확도를 확인.

### 5.2 절차
1. 소스 Nginx upstream 수정: legacy 90%, 신규 10%로 반영  
   - nginx에서는 퍼센트가 아니라 **weight(가중치) 기반 라우팅**이다.  
   - 예: `weight 9`(legacy), `weight 1`(new) → 대규모 트래픽에서 약 90:10 분배 근사
2. 동일한 부하 파라미터로 `cutover-monitor.js` 실행(동일 duration/rps)
3. 응답코드, 에러구간, 다운타임, 타임라인, ASG/TG 상태 동기점검

### 5.3 결과(수집값)
- `checks`: **100.00%**
- `cutover_read_error_rate`: **0.00%**
- `cutover_total_error_rate`: **0.00%**
- `http_req_failed`: **0.00%**
- `cutover_unplanned_downtime_total_ms`: **0ms**
- `cutover_response_time p95`: **16.12ms**

### 5.4 분석
read/write probe 모두 동일 관측점 기준으로 실행했을 때 정상 전환 혼입 시나리오에서도 에러율 임계치를 초과하지 않았고, 다운타임도 없음.

### 5.5 조치
- 소스 upstream은 즉시 100% legacy로 복구
- read/write probe는 현재 기준 설정 그대로 운영 가능
  - `X-Backend-Env` 헤더 기반 전환 비율/버전 분기 모니터링 유지

---

## 6. 시나리오 C — 장애 유발 실험(컨테이너 중단)

### 6.1 목적
실제 전환 중 장애가 났을 때 plan 섹션 11, 13 롤백 판단을 얼마나 빨리 내릴 수 있는지 확인.

### 6.2 절차
1. 소스 upstream은 legacy 90%, 신규 10%(weight 9:1) 상태 유지
2. 신규 ASG 인스턴스(`10.0.1.15`)에서 `docker stop billage-rehearsal-be` 실행
3. 동일 세션에서 부하 유지
4. k6 timeline/다운타임, ALB TG 상태, ASG 상태 동시 모니터링
5. 컨테이너 재기동 및 정상 복구

### 6.3 관측
- 신규 타깃으로 라우팅된 요청에서 **502**로 즉시 변환
- timeline 로그에서 `TIMELINE_DOWN_START ... status=502`, `TIMELINE_RECOVERY ... downtimeMs=512~567` 형태의 단발성 장애 구간 확인
- 단건 단위로 ms 단위의 다운 발생(짧은 단발 장애 다수)
- TG에서 `draining/initial/inservice` 상태 전이가 실패 응답과 정합됨

### 6.4 해석
- 8 rps의 비교적 낮은 부하 조건에서도 단일 인스턴스/단일 요청 구간은 즉시 영향
- 오류가 장기화되지 않으면 모니터링 기준상 **재현성 있는 단발 장애**로 분류 가능
- Plan의 가중치 증분을 늘리는 순간(10% → 25% 이상) 또는 신규 인스턴스 교체 동시 진행 시에는 실제 사용자 체감 증가 가능성 있음

### 6.5 조치
- 유입이 신규로 가는 구간에서 장애 발생 시 `target group`/`upstream` 롤백 시점 임계값을 엄격 적용
- 장애 구간 재현 시 ALB TG 상태를 함께 로그화해 “어떤 레이어에서 실패했는지”를 분리

---

## 7. 정상/실패 비교 요약

### 7.1 비교표
| 항목 | 시나리오 A(베이스라인) | 시나리오 B(legacy 90%, 신규 10%, weight 9:1 컷오버) | 판정 |
|---|---:|---:|---|
| 기간 | 2m | 2m | 동일 비교군 |
| RPS | 8 | 8 | 동일 |
| read error rate | 0.00% | 0.00% | 정상 |
| total error rate | 0.00% | 0.00% | 정상 |
| unplanned downtime | 0ms | 0ms | 무관/단발 이슈 |
| p95 | 18.17ms | 19.89ms | 정상 범위 |
| 임계치(0.1%) 초과 여부 | 미초과 | 미초과 | 통과 |

### 7.2 결론
- 베이스라인은 안정적이다.
- 컷오버 90:10(weight 9:1) 혼입 시에도 에러율/장애 지표는 임계치 내에서 통과.
- 해당 지표는 기준선 대비 비교 평가 기준을 충족하므로 전환 게이트 통과 조건으로 이어질 수 있다.

---

## 8. 문서 반영 및 향후 할 일(계획 연동)

### 8.1 계획 반영 항목 정리
1. `X-Backend-Env` 및 버전 식별 헤더를 기준으로 응답 출처를 확실히 추적하도록 운영 지표 통일
2. read/write probe를 “인증 영향을 최소화한 공통 경로”로 정렬
3. 시나리오 B 수행 전/후로 baseline 재취득(매 회차 실행)
4. 장애 발생 시 `cutover_total_error_rate` 0.1% 초과를 즉시 판정 기준으로 운용
5. Phase 3/4 진행 전, 시나리오 A 성공 + probe 정합성 통과를 게이트 조건으로 추가

### 8.2 다음 실험(권장)
- baseline + legacy 90%, 신규 10%(weight 9:1) 재실행(health에서 공통 인증 경로로 교체)
- 그 다음 50:50, 90:10, 100% 전환 구간으로 증분 확대
- ASG 스케일 변화(최소 2개 인스턴스) 시나리오에서 동일 지표 재측정

---

## 9. 시행결론
이번 리허설은 “환경 기본선 확보”와 “컷오버 시나리오 비교”가 **실제 수치로 분리**되어 수행되었고,  
무작정 신규 비율을 늘리는 방식이 아니라 **plan 기반의 관측/롤백/분류 체계**로 접근해야 함을 확인했다.

현재 시점에서 즉시 반영 가능한 우선순위는 다음이다.
1. `read probe` 정합성 수정
2. 기준선/전환군 실행 템플릿 고정
3. plan의 임계치(특히 에러율)로 다시 cutoff 테스트 수행 후 Phase 2 다음 단계 진행
