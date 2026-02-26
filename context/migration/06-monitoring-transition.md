# Billage v1→v2 모니터링 전환 계획

## 1. 개요 (300K MAU 기준)

모니터링은 마이그레이션의 선행 조건이다. 300K MAU 규모의 ~900 RPS 트래픽에서 "보이지 않는 것은 관리할 수 없다"는 관찰성의 핵심 원칙을 따라, v2 인프라로의 전환은 v1과 동등한 수준의 가시성을 확보한 후에만 진행되어야 한다.

현재 v1은 중앙화된 Management VPC에서 Prometheus 2.50.0, Grafana 10.3.0, Loki 2.9.0 스택으로 완전한 관찰성을 제공하고 있다. v2 마이그레이션 시 이 기능성을 그대로 유지하되, 동적 ASG 기반 인스턴스 환경에 맞게 발전시켜야 한다.

본 문서는 모니터링 인프라가 v1과 v2를 동시에 커버하는 과도기 상태를 정의하고, v2 프로덕션 안정화 후 v1 레거시 모니터링을 정리하는 경로를 제시한다.

---

## 2. 현재 상태 (AS-IS)

### 2.1 아키텍처 개요

v1 모니터링은 Management VPC (10.2.0.0/16)의 단일 Private Subnet (10.2.2.0/24)에 집중된 구조이다. t4g.small 인스턴스에서 Docker Compose로 운영되는 Prometheus, Grafana, Loki는 VPC Peering (hub-spoke 토폴로지)을 통해 Dev 및 Prod 환경의 모든 리소스와 통신한다.

### 2.2 메트릭 수집 계층 (Prometheus) - 300K MAU 기준

Prometheus 2.50.0은 EC2 Service Discovery(ec2_sd_configs) 방식으로 Role=monitoring-target 태그를 가진 모든 EC2 인스턴스를 자동 탐색한다. v1 환경에서는 약 5-10개 인스턴스를 모니터링하고, v2 환경에서는 최대 6개 백엔드 + 3개 프론트엔드 + 2개 AI = 11개 인스턴스를 모니터링한다.

**Prometheus 스크랩 대상 (v1 + v2 병렬 운영 시):**
- v1: 5-10개 인스턴스 × 4개 작업 = 20-40개 타겟
- v2: 11개 인스턴스 × 4개 작업 = 44개 타겟
- 총합: 64-84개 스크랩 타겟

node-exporter 작업은 포트 9100에서 CPU, 메모리, 디스크, 네트워크 등 시스템 메트릭을 수집한다. cAdvisor는 포트 8082에서 Docker 컨테이너 메트릭(CPU 사용률, 메모리, 네트워크 I/O)을 수집하며, 이는 Docker 소켓을 마운트한 특권 모드 컨테이너에서 실행된다. spring-actuator 작업은 포트 8080에서 Spring Boot 애플리케이션의 내부 메트릭(요청 수, GC 통계, 스레드 풀 상태)을 수집한다. mysql-exporter는 포트 9104에서 마스터 데이터베이스의 쿼리 성능, 리플리케이션 상태, 연결 풀 정보를 수집한다.

데이터 보관 기간은 15일이며, TSDB(Time-Series Database) 압축 형식으로 저장되어 저장소 효율성을 극대화한다.

### 2.3 로그 수집 계층 (Loki + Promtail)

Loki 2.9.0은 15일 메트릭 보관 후 로그 플랫폼 역할을 수행한다. 각 대상 인스턴스에 배포된 Promtail은 포트 3100의 Loki 서버로 로그를 푸시한다. 90일 보관 정책(retention: 90d)을 적용하여 중기 감사 및 문제 재현 요구사항을 충족한다.

Promtail 구성은 Spring Boot 멀티라인 로그 파싱(java.lang.Exception 스택 트레이스, Caused by 패턴 인식) 및 Nginx 접근 로그 파싱을 지원한다. 상태코드 추출, 응답시간 계측, 클라이언트 IP 필터링이 라벨(label) 형태로 자동화되어 Loki 쿼리 시 즉시 활용 가능하다.

### 2.4 접근 제어 및 가시성

Grafana는 VPN(WireGuard)을 통해서만 접근 가능하며, 포트 3000에서 운영된다. Prometheus도 포트 9090으로 제한된 접근만 허용한다. 이는 민감한 메트릭 정보(데이터베이스 연결 수, API 응답 시간, 에러율)를 내부 인력만 볼 수 있도록 보호한다.

### 2.5 알림 체계

CloudWatch 기반 알림 규칙(CPU > 80%, StatusCheck 실패)은 SNS 주제로 발행되고, Lambda 함수를 거쳐 Discord 웹훅으로 전달된다. 이는 Prometheus 알림 규칙과 독립적으로 작동하며, CloudWatch 네이티브 메트릭(EC2, ALB, RDS 기본 메트릭)을 감시한다.

---

## 3. 목표 상태 (TO-BE)

### 3.1 동적 인스턴스 환경 대응 (300K MAU 기준)

v2 마이그레이션은 Auto Scaling Group 기반의 동적 인스턴스 풀로 변경된다. 300K MAU 기준으로:
- Backend ASG: min 2, max 6 인스턴스
- Frontend ASG: min 2, max 3 인스턴스
- AI ASG: min 1, max 2 인스턴스

이는 Prometheus의 기존 EC2 Service Discovery 기능이 자동으로 새 인스턴스를 감지하고 스크랩 대상에 추가함을 의미한다. 따라서 Prometheus 설정 변경 없이 v2 ASG에 속한 인스턴스들이 자동으로 모니터링 대상에 포함된다. 최악의 경우 11개 인스턴스 × 4개 작업 = 44개 스크랩 타겟이 추가되며, Prometheus 메모리 증설이 필요할 수 있다.

### 3.2 클라우드 네이티브 메트릭 통합

v2 인프라는 Application Load Balancer, RDS, RabbitMQ를 사용하므로, 이들 AWS 관리형 서비스의 메트릭을 CloudWatch를 통해 수집한다. ALB는 RequestCount, ResponseTime, HTTPCode_Target_5XX, HealthyHostCount를 노출하고, RDS는 DatabaseConnections, Queries, CPUUtilization, FreeableMemory, ReadIOPS, DiskQueueDepth를 제공한다. RabbitMQ (Phase 2에서 도입, 현재 선택사항)는 Queue Depth, Consumer Count, Publish Rate, Memory Usage를 메트릭으로 제공할 예정이다.

### 3.3 통합 대시보드 및 알림

기존 v1 대시보드는 유지되며, v2 전용 대시보드가 새로 생성된다. 마이그레이션 기간 동안 v1과 v2 트래픽, 에러율, 응답시간을 비교하는 임시 대시보드가 의사결정 기준이 된다. 알림 규칙은 v2 특화 조건(ASG 스케일 한계 도달, 컨테이너 재시작 빈도, RDS 메모리 압박)을 포함하도록 확대된다. Phase 2에서 RabbitMQ가 도입되면 Queue Depth, Consumer Count 모니터링도 추가할 예정이다.

---

## 4. 변경 불필요 항목 (기존 구성 활용)

### 4.1 Prometheus EC2 Service Discovery

Prometheus는 이미 EC2 메타데이터 API를 통해 태그 기반 인스턴스 탐색 기능을 갖추고 있다. v2 인스턴스에 Role=monitoring-target 태그를 적용하면 자동으로 Prometheus 스크랩 대상 목록에 추가된다. 이는 Prometheus 설정 파일 수정 불필요를 의미한다.

### 4.2 cAdvisor 포트 및 수집 메커니즘

cAdvisor는 포트 8082로 고정되어 있고, v2 인스턴스에도 동일 포트에서 실행될 예정이다. 따라서 Prometheus 스크랩 작업에서 기존 `:8082/metrics` 엔드포인트 설정을 그대로 사용할 수 있다.

### 4.3 VPC Peering 연결

Management VPC와 Dev VPC 간 피어링은 이미 구성되었으며, v2 인스턴스들이 배치될 Dev VPC Private Subnet과 라우팅도 완료된 상태이다. 추가 네트워크 설정은 불필요하다.

### 4.4 Grafana 및 Loki 서버 유지

Prometheus, Grafana, Loki 서버는 Management VPC에서 계속 운영된다. 새로운 수집 대상이 늘어날 뿐, 백엔드 서버 자체는 변경되지 않는다.

---

## 5. 변경 필요 항목

### 5.1 v2 인스턴스 모니터링 에이전트 설치

v2 인스턴스 시작 시점에 node-exporter, cAdvisor, Promtail을 컨테이너 또는 바이너리 형태로 설치해야 한다. 이는 ASG launch template의 user_data 스크립트에 통합되어야 하며, 다음 순서로 실행되어야 한다:

첫째, Docker 엔진을 설치하고 시작한다. 둘째, 디스크, 패키지 의존성을 확인한 후 node-exporter 바이너리를 설치한다(systemd service로 자동 시작). 셋째, cAdvisor 컨테이너를 실행하며, 이 때 docker.sock 마운트(볼륨: /var/run/docker.sock:/var/run/docker.sock)로 호스트의 모든 컨테이너를 감시하도록 한다. 특권 모드(privileged: true) 설정이 필수이다. 넷째, Promtail 컨테이너를 실행하며, /var/lib/docker/containers 디렉토리를 마운트하여 Docker json-file 로그 드라이버의 로그 파일에 접근한다. 다섯째, 애플리케이션 컨테이너(Spring Boot 백엔드, 프론트엔드, AI 모듈)를 시작한다.

이 순서는 메트릭 및 로그 수집 기반이 먼저 준비된 후 애플리케이션이 시작되도록 보장한다.

### 5.2 Prometheus 스크랩 설정 보강

v1 스크랩 작업(node-exporter, cAdvisor, spring-actuator, mysql-exporter)은 유지되며, v1 인스턴스들은 기존 식별 메커니즘으로 계속 수집된다.

v2 인스턴스 구분을 위해 relabel_configs에 새 라벨을 추가한다. infra_version=v2 라벨을 모든 v2 대상에 부여하고, 추가로 ASG 태그(Environment=prod-v2, Service=backend 등)를 파싱하여 Service 라벨로 추출한다. 이는 Prometheus 쿼리 시 {infra_version="v2", service="backend"}와 같은 세밀한 필터링을 가능하게 한다.

### 5.3 MySQL Exporter에서 RDS CloudWatch로 전환

v1의 mysql-exporter(포트 9104)는 마스터 데이터베이스로부터 직접 메트릭을 수집해 왔다. v2에서는 RDS 관리형 데이터베이스로 마이그레이션되므로, mysql-exporter 작업을 제거하는 대신 CloudWatch 데이터소스를 활용한다.

전환 시점은 데이터베이스 마이그레이션 완료 후이다. 마이그레이션 기간 동안 v1 mysql-exporter와 v2 RDS CloudWatch 메트릭을 병행 수집하여 데이터 연속성을 보장한다.

### 5.4 Grafana CloudWatch 데이터소스 추가

Grafana에 새로운 데이터소스를 추가한다. 데이터소스 유형은 CloudWatch이며, AWS 인증 방식으로 IAM 역할을 사용한다. Prometheus EC2 인스턴스에 IAM 인스턴스 프로필을 할당하고, 해당 역할에 cloudwatch:GetMetricData, cloudwatch:ListMetrics, ec2:DescribeInstances 권한을 부여한다.

이 데이터소스를 통해 ALB, RDS, ASG의 메트릭을 Grafana 대시보드에 직접 시각화할 수 있다. Phase 2에서 RabbitMQ 도입 시 RabbitMQ management API 데이터소스도 추가할 예정이다.

### 5.5 Promtail 설정 변경

v1 Promtail은 호스트 파일 시스템(/var/log/billage/ 디렉토리)의 애플리케이션 로그를 수집했다.

v2에서는 모든 애플리케이션이 컨테이너로 실행되므로, Promtail이 Docker json-file 로그 드라이버의 로그 파일(/var/lib/docker/containers/*/*.log)을 수집하도록 변경된다. 이를 통해 컨테이너 stdout/stderr이 자동으로 Loki에 전달된다.

Promtail 설정에 추가될 라벨은 service_name(backend, frontend, ai 등), instance_id(EC2 인스턴스 ID), environment(prod-v2), infra_version(v2)이다. 이 라벨들은 Loki 쿼리(logql)에서 {service_name="backend", infra_version="v2"})로 접근 가능하게 한다.

---

## 6. v2 Grafana 대시보드 설계

### 6.1 대시보드 1: v2 Overview (핵심 시스템 상태)

목적: v2 인프라 전체 상태를 한눈에 파악하는 진입점.

구성 요소:
- ASG 현황 패널: 서비스별(backend, frontend, ai)로 Desired Capacity, InService 인스턴스 수, Pending 상태 인스턴스를 표시. 스케일 아웃/인 추이를 라인 그래프로 표현.
- ALB 요청 처리량: 초당 요청 수(RequestCount / 60초 평균) 및 에러율(HTTPCode_Target_5XX / Total requests × 100).
- 응답시간 p95: ALB TargetResponseTime p95 분위수.
- 전체 상태 지표: Healthy host count, Unhealthy host count, Active connection count.

### 6.2 대시보드 2: ALB & Target Group 상세

목적: 로드 밸런싱 계층의 정밀한 분석.

구성 요소:
- Target Group별 패널: 각 Target Group(backend-tg, frontend-tg)에 대해 Healthy/Unhealthy host count를 게이지로 표시.
- HTTP 상태코드 분포: 막대 그래프로 2xx, 3xx, 4xx, 5xx 응답 수를 시간대별로 표현. 특히 5xx 에러 급증 시 즉시 인지 가능.
- 응답시간 히스토그램: p50, p95, p99 응답시간을 스택 바 차트로 표현.
- 느린 요청 추이: ResponseTime이 5초를 초과하는 요청의 시계열 데이터.

### 6.3 대시보드 3: 인스턴스 & 컨테이너 상세

목적: 개별 인스턴스 및 컨테이너 리소스 모니터링.

구성 요소:
- 인스턴스별 CPU/Memory: node-exporter에서 수집한 node_cpu_seconds_total, node_memory_MemFree_bytes를 인스턴스 ID별로 그룹화. 색상 코딩으로 임계값 초과(CPU > 80%, Memory > 85%) 표시.
- 컨테이너별 CPU/Memory/Network: cAdvisor의 container_cpu_usage_seconds_total, container_memory_usage_bytes, container_network_transmit_bytes_total를 컨테이너 이름(service_name 라벨) 기준으로 렌더링.
- 컨테이너 재시작 빈도: container_last_seen 메트릭 기반으로 컨테이너 재시작 횟수를 계산(PromQL: count_over_time(container_last_seen[1h])).

### 6.4 대시보드 4: 데이터 레이어 (RDS & Redis)

목적: 데이터 저장소 상태 모니터링.

구성 요소:
- RDS 메트릭:
  - DatabaseConnections: 활성 데이터베이스 연결 수(누적 라인 그래프).
  - Queries: 초당 쿼리 수(QPS).
  - CPUUtilization: CPU 사용률 백분율.
  - FreeableMemory: 사용 가능한 메모리(바이트 → GB 변환).
  - ReadIOPS, WriteIOPS: 읽기/쓰기 I/O 작업 초당 수.
  - DiskQueueDepth: 대기 중인 I/O 작업 큐 길이.

- Redis 메트릭:
  - CurrConnections: 현재 연결 수(게이지).
  - CacheHitRate: 캐시 적중률(백분율).
  - EngineCPUUtilization: Redis 엔진 CPU 사용률.
  - FreeableMemory: 사용 가능한 메모리(현재 메모리 대비).
  - PublishedSubscriptionChannels: Pub/Sub 활성 채널 수.

### 6.5 대시보드 5: 마이그레이션 비교 (임시, Phase 2 이후 제거)

목적: v1과 v2의 성능 지표를 실시간 비교하여 마이그레이션 안정성 판단.

구성 요소:
- v1 vs v2 트래픽 비율: 파이 차트로 ALB 요청 수 기준 분배율 표시. 예: v1 60%, v2 40%.
- v1 vs v2 에러율 비교: 이중 축 라인 그래프로 각 버전의 5xx 에러율 추이.
- v1 vs v2 응답시간 비교: 박스 플롯 또는 분위수 차트로 p50, p95, p99 응답시간 비교.
- v1 vs v2 서비스별 성능: 테이블 형식으로 각 마이크로서비스(backend, frontend, ai) 기준 메트릭 비교.

---

## 7. 알림 전환

### 7.1 기존 v1 알림 규칙 유지

CPU 사용률 > 80%(모든 인스턴스), StatusCheck 실패는 v1 인스턴스에 대해 계속 적용된다. 이 알림들은 CloudWatch의 기본 메트릭을 기반으로 하며, Discord 웹훅을 통해 전달된다.

### 7.2 신규 v2 알림 규칙 추가

v2 환경 특화 알림:

- ALB 5xx 에러 > 10건/5분: HTTPCode_Target_5XX 메트릭이 5분간 10을 초과. 의미: 백엔드 서비스 장애 또는 과부하 신호. 심각도: 높음(Critical).

- ASG InServiceInstances = MaxSize: 스케일 한계 도달. 의미: ASG가 최대 용량에 도달했음을 나타내며, 추가 요청에 대한 스케일 아웃 불가능. 심각도: 높음(Critical). 대응: ASG MaxSize 증가 또는 트래픽 재분배 검토.

- 컨테이너 재시작 > 0: 이전 15분 동안 컨테이너가 재시작된 경우. 의미: 애플리케이션 크래시 또는 health check 실패. 심각도: 중간(Warning). 대응: 로그 확인.

- RDS FreeableMemory < 500MB: RDS 인스턴스의 사용 가능 메모리 부족. 의미: 데이터베이스 성능 저하 임박. 심각도: 높음(Critical). 대응: RDS 인스턴스 타입 업그레이드 검토.

- RDS DatabaseConnections > 80% of max_connections: 데이터베이스 연결 풀 포화 임박. 의미: 새로운 데이터베이스 연결 수락 불가능 위험. 심각도: 높음(Critical). 대응: 연결 풀 설정 검토, 데이터베이스 인스턴스 업그레이드.

- RabbitMQ Queue Depth > 100K: RabbitMQ 큐의 미처리 메시지 수 100,000 초과. 의미: 메시지 처리 지연, 메모리 부족 임박. 심각도: 중간(Warning). 대응: Consumer 확인, 처리 속도 개선 (Phase 2). 현재 Phase 1에서는 미적용.

### 7.3 알림 전달 채널

모든 알림은 기존 Discord 웹훅을 통해 전달되며, 심각도별 색상 코딩(Critical: 빨강, Warning: 노랑)으로 구분된다. 알림 메시지는 서비스 이름, 영향 범위(인스턴스 수, 컨테이너 수), 권장 대응책을 포함한다.

---

## 8. 실행 계획

### Step 1: v2 인스턴스 user_data 수정 (WAS 마이그레이션 전, Week 1-2)

ASG launch template의 user_data 스크립트에 다음 항목을 추가한다:
- Docker 설치 및 시작
- node-exporter 바이너리 설치(systemd service 등록)
- cAdvisor 컨테이너 실행(docker run with /var/run/docker.sock mount, privileged mode)
- Promtail 컨테이너 실행(docker run with /var/lib/docker/containers mount)
- EC2 인스턴스에 Role=monitoring-target, Environment=prod-v2, Service=backend(또는 frontend/ai) 태그 적용 확인

검증: ASG 내 v2 인스턴스 하나 시작 후 Prometheus Targets 페이지에서 자동 등록 확인.

### Step 2: Grafana CloudWatch 데이터소스 추가 (Week 2)

Grafana UI에서 Configuration > Data Sources > Add new data source > CloudWatch 선택.
AWS 인증: IAM role (Prometheus EC2 인스턴스 역할).
권한 부여: 해당 IAM 역할에 cloudwatch:GetMetricData, cloudwatch:ListMetrics, ec2:DescribeInstances 인라인 정책 추가.
테스트: RDS, ALB, Redis 메트릭 검색 가능 확인.

### Step 3: v2 대시보드 생성 (Week 2-3)

대시보드 1(v2 Overview), 2(ALB & Target Group), 3(인스턴스 & 컨테이너), 4(데이터 레이어)를 순서대로 생성.
각 대시보드의 패널은 PromQL 및 CloudWatch 메트릭 쿼리 조합으로 구성.
테스트: 의도적으로 트래픽 증가/컨테이너 재시작 등을 유도하여 대시보드 데이터 갱신 확인.

### Step 4: v2 알림 규칙 추가 (Week 3)

CloudWatch에 신규 알림 규칙 7개(ALB 5xx, ASG max reached, container restart, RDS memory, RDS connections, Redis memory, 및 기타 추가 규칙) 생성.
SNS 주제 및 Lambda 함수는 기존 v1 알림과 동일하게 사용(Discord 웹훅 통합).
테스트: 의도적 임계값 초과(예: CPU stress로 CPU > 80% 달성, ALB 응답 지연으로 5xx 에러 발생) 후 Discord 알림 수신 확인.

### Step 5: 마이그레이션 비교 대시보드 생성 (Week 3, Blue-Green 배포 시)

v1 ALB와 v2 ALB의 메트릭을 동시에 시각화하는 대시보드 생성.
Traffic shift 비율(v1 60% → v2 40% → v1 40% → v2 60% 등)을 라인 그래프로 표시.
각 단계에서 에러율, 응답시간, 리소스 사용률 비교 수행.

### Step 6: DB 마이그레이션 후 MySQL Exporter 제거 (Database Migration 직후)

v1 mysql-exporter 스크랩 작업을 Prometheus 설정에서 제거.
RDS CloudWatch 메트릭 수집 확인 후 진행.

### Step 7: v1 정리 및 v1 대시보드 아카이브 (v2 안정화 후, Week 4+)

v1 인프라 서비스 종료(인스턴스, ALB 정지).
v1 대시보드를 Grafana 폴더 "Legacy v1 (Archived)"로 이동하여 보존(감사 및 과거 데이터 추적용).
Prometheus 설정에서 v1 관련 스크랩 작업 모두 제거.

---

## 9. 검증 방법

### 9.1 v2 인스턴스 자동 탐색

v2 ASG에서 새 인스턴스 1개 시작. 5분 대기 후 Prometheus 웹 UI(http://[prometheus-ip]:9090/targets) 접근. node-exporter, cAdvisor, spring-actuator 타겟이 자동으로 목록에 추가되었는지 확인. 상태가 "UP"인지 확인(통신 정상).

### 9.2 Scale-out 자동 감지

ASG desired capacity를 N+1로 증가. 새 인스턴스 시작 대기. Grafana v2 Overview 대시보드에서 ASG InService 인스턴스 수가 실시간 증가 반영되는지 확인. 대시보드 새로고침 없이 자동 업데이트 확인.

### 9.3 로그 수집

v2 인스턴스의 컨테이너에서 테스트 로그 생성(예: echo "test log" 또는 예외 발생). Grafana Loki 데이터소스 쿼리(Explore > Loki > {infra_version="v2"})에서 해당 로그 검색 가능 확인.

### 9.4 CloudWatch 메트릭 가시화

Grafana 데이터소스 설정에서 CloudWatch > Test 실행. ALB, RDS, Redis 메트릭 검색 가능 확인. 대시보드 4(데이터 레이어)의 모든 패널이 데이터를 표시하는지 확인.

### 9.5 알림 테스트

의도적 CPU stress 테스트: v2 인스턴스에서 stress 명령 실행(stress --cpu 4 --timeout 600s). 5분 내 CPU > 80% 달성 후 Discord 알림 수신 확인.

ALB 5xx 에러 테스트: 백엔드 서비스의 health check endpoint를 일시적으로 장애 상태로 설정. ALB가 unhealthy로 표시, 5xx 에러 발생 후 Discord 알림 수신 확인.

RDS 연결 포화 테스트: 애플리케이션에서 의도적으로 다수의 데이터베이스 연결 유지. RDS DatabaseConnections > 80% 임계값 도달 후 Discord 알림 수신 확인.

---

## 10. Fallback 및 응급 대응

### 10.1 모니터링 인프라 장애 시나리오

모니터링 장애는 마이그레이션 자체 성공 여부와 직접 연관이 없다. 애플리케이션은 독립적으로 운영되며, 모니터링 부재 상황에서도 서비스 가용성은 유지된다. 그러나 "보이지 않는 상태"로 마이그레이션을 진행하는 것은 위험도를 높이므로, 다음 응급 대응 절차를 수립한다:

### 10.2 Prometheus 다운 (메트릭 수집 불가)

즉시 대응: CloudWatch 네이티브 대시보드(AWS Console > CloudWatch > Dashboards)로 전환. ALB, RDS, EC2 기본 메트릭(CPU, 네트워크)은 CloudWatch에서 직접 조회 가능.

장기 대응: Prometheus 서비스 재시작(docker-compose -f /opt/monitoring/docker-compose.yml restart prometheus). 서비스 복구 후 메트릭 재수집 시작(최근 15일 데이터 유실).

### 10.3 Loki 다운 (로그 수집 불가)

즉시 대응: v2 인스턴스에 직접 SSH 접속 후 docker logs 명령으로 컨테이너 로그 조회. 예: docker logs [container_id] --tail 100.

장기 대응: Loki 서비스 재시작(docker-compose -f /opt/monitoring/docker-compose.yml restart loki). Promtail은 Loki 복구 시 자동으로 재연결 시도.

### 10.4 Grafana 다운 (대시보드 불가)

Prometheus API 직접 조회: curl "http://[prometheus-ip]:9090/api/v1/query?query=up". PromQL로 메트릭 검색 가능.

CloudWatch 콘솔: AWS Console에서 직접 메트릭 조회 및 임시 대시보드 생성.

장기 대응: Grafana 서비스 재시작(docker-compose -f /opt/monitoring/docker-compose.yml restart grafana).

### 10.5 VPC Peering 또는 네트워크 연결 장애

증상: Prometheus가 v2 인스턴스의 스크랩 엔드포인트에 도달 불가(모든 타겟 DOWN).

확인: Management VPC에서 v2 Private Subnet의 인스턴스 IP로 ping 또는 curl 테스트. 실패 시 VPC Peering 상태 확인(AWS Console > VPC > Peering Connections > Status가 "Active"인지 확인). 라우트 테이블 확인(Management VPC의 라우트 테이블에 v2 CIDR 목적지에 대한 peering connection 경로 존재 여부).

대응: Peering connection 재설정 또는 대체 네트워크 경로 구성.

---

## 11. 리스크 및 완화 전략

### 11.1 Prometheus 메모리 부족 (300K MAU 기준)

위험: v1과 v2를 동시에 모니터링하는 과도기 동안, 스크랩 대상 수 증가로 인해 Prometheus 메모리 사용률 급증.

현재 상태:
- v1: 5-10개 인스턴스 × 4개 작업 = 20-40개 타겟
- v2 추가: 11개 인스턴스 × 4개 작업 = 44개 타겟
- **총합: 64-84개 스크랩 타겟 (2배 이상 증가)**

완화 전략:
- Prometheus 메모리 상한 모니터링: Grafana에 process_resident_memory_bytes 메트릭 패널 추가. 임계값 80% 도달 시 알림.
- Prometheus 인스턴스 스펙 사전 증설: t4g.small(1GB) → t4g.medium(4GB)으로 업그레이드(v2 마이그레이션 시작 전). **필수 사항.**
- v1 스크랩 주기 조정: v1은 scrape_interval 60s로 변경(기존 30s), v2는 30s 유지하여 부하 분산.
- 메트릭 샘플 제한: Prometheus 설정의 scrape_configs에서 metric_relabel_configs를 추가하여 불필요한 메트릭(예: node_* 중 일부) 제거.
- v1 정리 후 메모리 복원: v1 종료 후 Prometheus를 t4g.small으로 다운그레이드 가능.

### 11.2 Promtail Docker 로그 경로 미연결

위험: v2 인스턴스의 Promtail이 /var/lib/docker/containers/ 디렉토리를 마운트했으나, Docker 로그 파일 생성 경로 변경 또는 로그 드라이버 설정 오류로 인해 로그 수집 불가.

완화 전략:
- user_data 스크립트에서 Docker 로그 드라이버 명시 설정: docker daemon.json에서 "log-driver": "json-file"을 명시. 기본값이므로 문제 가능성 낮음.
- Promtail 시작 후 로그 수집 확인: user_data에 sleep 30 && docker logs [promtail_container_id] | grep "successfully"를 추가하여 정상 작동 확인.
- Promtail 설정 파일에 오류 로깅 추가: loki 로그 경로(/var/lib/docker/containers/*/) 존재 확인 스크립트를 초기화 과정에 포함.

### 11.3 CloudWatch API 호출 비용

위험: Grafana에서 CloudWatch 데이터소스를 통해 ALB, RDS, Redis 메트릭을 자주 조회할 경우, CloudWatch API 호출 수 증가로 인한 비용 상승.

AWS CloudWatch API 요금: 요청당 약 $0.01(GetMetricData). 1시간마다 100개 메트릭을 조회하면 월 약 $7,200.

완화 전략:
- Grafana 대시보드 쿼리 최적화: 불필요한 메트릭 제거, 집계 주기 조정(예: 1분 → 5분).
- CloudWatch 메트릭 수를 필수 항목만 수집: ALB는 5개(RequestCount, ResponseTime, HTTPCode_Target_5XX, HealthyHostCount, TargetResponseTime), RDS는 6개, Redis는 5개로 제한.
- AWS Observability Pricing을 고려한 Prometheus 메트릭 중심 운영: CloudWatch는 보조적 역할로 제한(월 1회 조회 또는 임시 대시보드).
- Reserved Capacity 활용: CloudWatch에 대한 committed capacity discount 검토(계약 시 비용 40% 절감).

### 11.4 VPC Peering 및 Private Subnet 라우팅 확인

위험: v2 인스턴스가 배치된 Private Subnet이 Management VPC Peering과 라우팅되지 않아, Prometheus가 v2 타겟에 도달 불가.

확인 체크리스트:
- VPC Peering: Management VPC와 v2 VPC 간 peering connection이 "Active" 상태인지 확인.
- 라우트 테이블: Management VPC의 Prometheus EC2가 속한 subnet의 라우트 테이블에 v2 Private Subnet CIDR(예: 10.3.2.0/24)에 대한 destination이 peering connection을 가리키고 있는지 확인.
- 보안 그룹: v2 인스턴스의 보안 그룹이 Management VPC CIDR 또는 Prometheus EC2의 보안 그룹으로부터의 인바운드 트래픽(포트 9100, 8082, 8080 등)을 허용하는지 확인.
- NACL: v2 Private Subnet의 Network ACL이 Management VPC로부터의 인바운드 트래픽을 차단하지는 않는지 확인.

완화 전략: 마이그레이션 시작 전, 네트워크 아키텍트와 함께 이 항목들을 사전 검증.

---

## 12. 마이그레이션 체크리스트 (최종 검증)

마이그레이션 실행 전 다음 항목들을 확인하고, 모두 충족해야 v2 트래픽 전환을 진행한다:

**인프라 준비:**
- [ ] ASG launch template user_data에 node-exporter, cAdvisor, Promtail 설치 스크립트 추가 완료
- [ ] v2 인스턴스에 Role=monitoring-target, Environment=prod-v2 태그 적용 확인
- [ ] Prometheus EC2에 IAM 역할(cloudwatch:GetMetricData 등) 할당 완료
- [ ] VPC Peering Management↔v2 active 상태, 라우팅 확인 완료

**모니터링 준비:**
- [ ] Grafana CloudWatch 데이터소스 추가, 테스트 완료
- [ ] v2 대시보드 1-4 생성, v1 대시보드와 함께 표시 확인
- [ ] v2 알림 규칙 7개(ALB 5xx, ASG max, container restart 등) 생성, 테스트 완료
- [ ] Discord 웹훅 v2 알림 수신 확인

**검증 완료:**
- [ ] v2 테스트 인스턴스 시작 → Prometheus Targets 자동 등록 확인
- [ ] v2 인스턴스에서 의도적 CPU stress → CloudWatch 알림 수신 확인
- [ ] Loki에서 v2 컨테이너 로그 검색 가능 확인
- [ ] ALB 5xx 에러 발생 → Discord 알림 수신 확인
- [ ] Grafana 대시보드에서 v1, v2 메트릭 동시 시각화 확인

**문서화:**
- [ ] user_data 스크립트, Prometheus 설정, Promtail 설정 Terraform 코드에 반영 완료
- [ ] 팀 내 모니터링 운영 매뉴얼(장애 대응, 새 대시보드 추가 절차) 작성 완료

---

## 결론

v1에서 v2로의 마이그레이션은 단순한 인프라 전환을 넘어, 관찰성(observability) 기준의 동등성을 갖춘 상태에서만 성공적이다. 본 계획은 v2 ASG 기반의 동적 인스턴스 환경에서도 Prometheus EC2 Service Discovery의 자동 탐색, Loki의 중앙화된 로그 수집, CloudWatch 메트릭의 AWS 네이티브 통합을 통해 v1 수준의 모니터링 능력을 유지하되, 새로운 인프라 구조에 맞게 발전시킨다.

특히 user_data를 통한 모니터링 에이전트 자동 배포, 마이그레이션 기간 v1과 v2의 병행 모니터링, 그리고 단계적 알림 규칙 확장은 운영 팀의 불안감을 최소화하고, 문제 발생 시 신속한 대응을 가능하게 한다.

이 계획을 성실하게 이행하면, Billage v2 마이그레이션은 "투명한 상태"에서 진행되며, 성능 저하 또는 장애 발생 시 즉시 인지하고 롤백할 수 있는 안전장치를 갖추게 된다. 모니터링은 단순한 연속성 확인이 아니라, 마이그레이션 자체의 신뢰도를 보장하는 핵심 기반이다.
