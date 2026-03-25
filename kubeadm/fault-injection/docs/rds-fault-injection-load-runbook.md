# RDS Fault Injection Load Runbook

## 근본 목적

이 문서는 `특정 비즈니스 API + 고정 RPS + 단계별 RDS latency 주입` 실험을 반복 가능하게 표준화해, 지연 전파 원인과 개선 전후 차이를 같은 방법으로 증명할 수 있게 만드는 데 목적이 있다.

## 비목적

이 문서는 일반적인 성능 테스트 전체를 다루는 문서가 아니며, 이번 범위 밖의 RabbitMQ 실험이나 컨트롤 플레인 장애 실험까지 포함하지 않는다.

## 1. 실험 개요

이번 정식 실험은 `Spring -> Toxiproxy -> RDS` 경로에 지연을 단계적으로 주입하면서, 실제 비즈니스 API 응답 시간과 애플리케이션 내부 포화 지표가 어떻게 변하는지 확인하는 데 초점을 둔다.

기본 흐름은 아래와 같다.

1. 대상 API 1개를 고정한다.
2. `k6`로 일정한 `RPS`를 유지한다.
3. `300ms -> 1s -> 3s` 순으로 `RDS latency toxic`를 올린다.
4. 각 단계마다 `p95`, `p99`, `5xx`, `Hikari`, `thread`, `HPA`, `restart`를 기록한다.
5. toxic 제거 후 recovery 구간을 본다.
6. 개선 적용 후 같은 조건으로 다시 반복한다.

## 2. 실험 대상

### 대상 API 선정 기준

대상 API는 아래 조건을 만족하는 엔드포인트 1개만 고른다.

- `RDS read`를 반드시 수행한다.
- 사용자가 실제로 자주 호출하는 API다.
- 응답 형태가 단순해 재현성이 좋다.
- 캐시 적중 여부로 결과가 크게 흔들리지 않는다.
- 쓰기 API보다 읽기 API를 우선한다.

### 추천 후보

- 게시글 목록 조회
- 게시글 상세 조회
- 채팅방 목록 조회
- 알림 목록 조회

### 권장 선택

가장 먼저는 `게시글 목록 조회 API`를 권장한다.

이유는 다음과 같다.

- 목록 조회는 동시성 부하를 주기 쉽다.
- RDS 질의 경로가 명확하다.
- 쓰기 경합, 중복 요청, 데이터 변형 같은 변수가 적다.
- 포트폴리오에서 설명이 쉽다.

## 3. 부하 프로파일

### 기본 부하

- 부하 도구: `k6`
- 시작 값: `RPS 50` 고정
- 실험 길이: 약 `45~55분`

### 단계별 시간표

1. baseline: `10분`
2. `300ms` latency: `10분`
3. `1s` latency: `10분`
4. `3s` latency: `5분`
5. recovery: `10분`

### 단계별 목적

- baseline
  - 평시 응답 분포와 평시 pool 상태 확인
- `300ms`
  - 평균은 버티지만 tail latency가 흔들리는지 확인
- `1s`
  - `Hikari pending`, `acquire latency`, `busy thread`가 나타나는지 확인
- `3s`
  - timeout, `5xx`, restart, readiness flap, HPA 반응까지 확인
- recovery
  - toxic 제거 뒤 얼마나 빨리 원복되는지 확인

## 4. 필수 전제 조건

실험 전 아래 조건이 모두 충족돼야 한다.

1. `toxiproxy-rds`가 Running 상태다.
2. Spring deployment가 `kube_latest` 이미지를 사용한다.
3. Spring datasource가 `toxiproxy-rds`를 본다.
4. toxic이 비어 있다.
5. `k6` 실행 위치와 네트워크 경로가 정리돼 있다.
6. Grafana/Prometheus 또는 대체 `kubectl` 관측 명령이 준비돼 있다.
7. 중단 기준과 롤백 절차가 팀 내에서 합의돼 있다.

## 5. 실험 전 확인 체크리스트

### 클러스터 상태 확인

```bash
/usr/bin/kubectl --kubeconfig /etc/kubernetes/admin.conf get pod -n billage-app -l app=spring-boot -o wide
/usr/bin/kubectl --kubeconfig /etc/kubernetes/admin.conf get pod -n billage-app -l app=toxiproxy-rds -o wide
/usr/bin/kubectl --kubeconfig /etc/kubernetes/admin.conf get deploy -n billage-app spring-boot -o wide
/usr/bin/kubectl --kubeconfig /etc/kubernetes/admin.conf get hpa -n billage-app spring-boot -o wide
```

기대 상태:

- Spring pod 전부 `Ready`
- `toxiproxy-rds` `1/1 Running`
- HPA가 이전 실험의 잔여 scale-up 상태가 아님

### toxic 비어 있는지 확인

```bash
/usr/bin/kubectl --kubeconfig /etc/kubernetes/admin.conf run fi-toxic-check -n billage-app --restart=Never --image=curlimages/curl:8.12.1 --command -- \
  sh -lc "curl -sS http://toxiproxy-rds:8474/proxies/rds-upstream"
/usr/bin/kubectl --kubeconfig /etc/kubernetes/admin.conf logs -n billage-app fi-toxic-check
```

기대 상태:

- `"toxics":[]`

### 대상 API 수동 호출 확인

```bash
curl -i "https://<target-host>/<target-api>"
```

기대 상태:

- `200`
- 응답 포맷 정상

## 6. k6 시나리오 설계

### 기본 원칙

- 하나의 API만 친다.
- think time 없이 일정 RPS를 유지한다.
- 인증이 필요하면 고정 토큰 또는 사전 로그인 토큰을 쓴다.
- 데이터셋은 캐시 영향이 과하지 않게 고정 범위를 사용한다.

### k6 스크립트 요구사항

- 대상 URL 1개만 반복 호출
- `RPS 50` 고정
- `status == 200` check
- `http_req_duration`, `http_req_failed`, `iteration_duration` 수집
- 단계 전환 시각을 로그에 남김

### 예시 변수

- `TARGET_BASE_URL`
- `TARGET_PATH`
- `AUTH_HEADER`
- `RPS`
- `DURATION_BASELINE`
- `DURATION_300MS`
- `DURATION_1S`
- `DURATION_3S`
- `DURATION_RECOVERY`

## 7. 단계별 실행 순서

## Step 1. Baseline 시작

실행:

1. Grafana 대시보드 2개를 열어 둔다.
2. `k6`를 시작한다.
3. `10분` 동안 toxic 없이 유지한다.

기록:

- 시작 시각
- 대상 API
- RPS
- 대상 pod 수
- HPA 상태

캡처:

- `Spring P95 Latency (ms)`
- `Nginx 5xx/s`
- `Hikari Pending Connections`
- `Hikari Acquire Latency (ms)`
- `ALB Ingress RPS`

## Step 2. 300ms 주입

실행:

```bash
/usr/bin/kubectl --kubeconfig /etc/kubernetes/admin.conf delete pod -n billage-app fi-toxic --ignore-not-found=true || true
/usr/bin/kubectl --kubeconfig /etc/kubernetes/admin.conf run fi-toxic -n billage-app --restart=Never --image=curlimages/curl:8.12.1 --command -- \
  sh -lc "curl -sS -X POST http://toxiproxy-rds:8474/proxies/rds-upstream/toxics \
  -H 'Content-Type: application/json' \
  -d '{\"name\":\"latency_downstream\",\"type\":\"latency\",\"stream\":\"downstream\",\"attributes\":{\"latency\":300,\"jitter\":50}}'; \
  echo; curl -sS http://toxiproxy-rds:8474/proxies/rds-upstream"
```

유지 시간:

- `10분`

관찰 포인트:

- `p95` 상승 시작
- `p99`가 먼저 흔들리는지
- `Hikari pending > 0` 출현 여부
- `Hikari acquire latency` 증가 여부
- `5xx`는 거의 없는지

캡처:

- 주입 직후 2분
- 주입 8분 시점

## Step 3. 1s 주입

실행:

```bash
/usr/bin/kubectl --kubeconfig /etc/kubernetes/admin.conf delete pod -n billage-app fi-toxic --ignore-not-found=true || true
/usr/bin/kubectl --kubeconfig /etc/kubernetes/admin.conf run fi-toxic -n billage-app --restart=Never --image=curlimages/curl:8.12.1 --command -- \
  sh -lc "curl -sS -X DELETE http://toxiproxy-rds:8474/proxies/rds-upstream/toxics/latency_downstream || true; \
  echo; \
  curl -sS -X POST http://toxiproxy-rds:8474/proxies/rds-upstream/toxics \
  -H 'Content-Type: application/json' \
  -d '{\"name\":\"latency_downstream\",\"type\":\"latency\",\"stream\":\"downstream\",\"attributes\":{\"latency\":1000,\"jitter\":100}}'; \
  echo; curl -sS http://toxiproxy-rds:8474/proxies/rds-upstream"
```

유지 시간:

- `10분`

관찰 포인트:

- `p95`, `p99` 급등
- `Hikari pending` 증가
- `Hikari timeout_total` 증가 시작
- Tomcat busy thread 증가
- 일부 endpoint timeout 또는 `5xx` 시작
- HPA scale-up 여부

캡처:

- 주입 직후 2분
- 최악 구간 1장

## Step 4. 3s 주입

실행:

```bash
/usr/bin/kubectl --kubeconfig /etc/kubernetes/admin.conf delete pod -n billage-app fi-toxic --ignore-not-found=true || true
/usr/bin/kubectl --kubeconfig /etc/kubernetes/admin.conf run fi-toxic -n billage-app --restart=Never --image=curlimages/curl:8.12.1 --command -- \
  sh -lc "curl -sS -X DELETE http://toxiproxy-rds:8474/proxies/rds-upstream/toxics/latency_downstream || true; \
  echo; \
  curl -sS -X POST http://toxiproxy-rds:8474/proxies/rds-upstream/toxics \
  -H 'Content-Type: application/json' \
  -d '{\"name\":\"latency_downstream\",\"type\":\"latency\",\"stream\":\"downstream\",\"attributes\":{\"latency\":3000,\"jitter\":200}}'; \
  echo; curl -sS http://toxiproxy-rds:8474/proxies/rds-upstream"
```

유지 시간:

- `5분`

관찰 포인트:

- `5xx` 급증
- timeout 증가
- `Hikari pending`, `timeout_total` 급증
- busy thread 포화
- restart / readiness flap
- HPA 재확대

캡처:

- 시작 1분
- 최악 구간 1분

중단 기준:

- `5xx`가 허용 범위를 넘음
- 사용자-facing 서비스에 명확한 장애 전파 발생
- restart loop 발생
- 운영자 판단으로 즉시 종료 필요

## Step 5. Recovery

실행:

```bash
/usr/bin/kubectl --kubeconfig /etc/kubernetes/admin.conf delete pod -n billage-app fi-toxic-cleanup --ignore-not-found=true || true
/usr/bin/kubectl --kubeconfig /etc/kubernetes/admin.conf run fi-toxic-cleanup -n billage-app --restart=Never --image=curlimages/curl:8.12.1 --command -- \
  sh -lc "curl -sS -X DELETE http://toxiproxy-rds:8474/proxies/rds-upstream/toxics/latency_downstream || true; \
  echo; curl -sS http://toxiproxy-rds:8474/proxies/rds-upstream"
```

유지 시간:

- `10분`

확인:

- `toxics: []`
- `p95/p99` 감소
- `Hikari pending` 정상화
- timeout 감소
- HPA cooldown 경과 후 replica 감소

캡처:

- toxic 제거 직후
- recovery 완료 직전

## 8. 반드시 찍어야 하는 사진

최소 8장은 남긴다.

1. baseline `Spring P95 Latency (ms)`
2. baseline `Hikari Pending Connections`
3. `300ms` 주입 중 `Spring P95 Latency (ms)`
4. `300ms` 주입 중 `Hikari Acquire Latency (ms)`
5. `1s` 주입 중 `Hikari Pending Connections`
6. `1s` 또는 `3s` 주입 중 `Nginx 5xx/s` 또는 `ALB Target 5xx/s`
7. `3s` 주입 중 `Container Restart Events (15m)` 또는 `kubectl get pods`
8. recovery 시점 `toxics: []` + `Spring P95 Latency (ms)`

## 9. 반드시 저장할 로그

아래 항목은 파일로 저장한다.

- toxic 설정 JSON
- toxic cleanup 결과
- `kubectl get pods -n billage-app -l app=spring-boot -o wide`
- `kubectl get hpa -n billage-app spring-boot -o wide`
- `kubectl logs -n billage-app deploy/toxiproxy-rds --tail=50`
- `k6` summary output
- 대상 API 응답 샘플

파일 저장 규칙:

- 디렉터리: `kubeadm/fault-injection/evidence/<YYYY-MM-DD>-rds-load-test/`
- 파일명 예시:
  - `01-baseline-k6-summary.txt`
  - `02-toxic-300ms.json`
  - `03-grafana-p95-baseline.png`
  - `04-grafana-p95-300ms.png`
  - `05-hikari-pending-1s.png`
  - `06-kubectl-pods-3s.txt`
  - `07-toxic-cleanup.txt`

## 10. Grafana/Prometheus 캡처 기준

### App Observability

- `Spring P95 Latency (ms)`
- `Spring 5xx Ratio`
- `Hikari Pending Connections`
- `Hikari Acquire Latency (ms)`
- `Hikari Connection Timeout/s`
- `Container Restart Events (15m)`

### Infra / RDS / ALB

- `ALB Ingress RPS`
- `ALB Target 5xx/s`
- `Hikari Active %`
- `Hikari Pending Connections`

### Prometheus 메트릭

- `http_server_requests_seconds_bucket`
- `http_server_requests_seconds_count`
- `hikaricp_connections_pending`
- `hikaricp_connections_timeout_total`
- `hikaricp_connections_acquire_seconds_sum`
- `hikaricp_connections_acquire_seconds_count`
- `aws_applicationelb_httpcode_target_5_xx_count_sum`
- `aws_applicationelb_request_count_sum`

## 11. 중단 기준

아래 중 하나라도 만족하면 즉시 toxic을 제거한다.

- `5xx`가 급격히 상승해 사용자 영향이 확인됨
- Spring pod restart loop
- HPA 급확대와 Pending 누적이 빠르게 진행됨
- 운영 담당자가 서비스 영향이 과하다고 판단

## 12. 종료 절차

1. toxic 제거
2. `toxics: []` 확인
3. `k6` 중단
4. Spring/HPA 상태 확인
5. evidence 파일 정리
6. 실행 보고서 작성

## 13. 개선 후 재실험 기준

아래 변경을 넣은 뒤 정확히 같은 조건으로 다시 반복한다.

- DB timeout 단축
- retry 상한 제한
- exponential backoff + jitter
- circuit breaker
- fallback 또는 degraded mode
- readiness에서 DB hard dependency 제거

비교표는 최소 아래 항목을 포함한다.

- baseline p95
- `300ms` p95
- `1s` p95 / p99
- `3s` 5xx
- `Hikari pending peak`
- `Hikari timeout_total`
- restart 발생 여부
- recovery 시간

## 14. 최종 산출물

실험 종료 후 아래 산출물을 남긴다.

1. 실행 보고서 Markdown 1개
2. evidence 디렉터리 1개
3. PR 요약 1개
4. 전/후 비교표 1개
5. 핵심 캡처 6~8장
