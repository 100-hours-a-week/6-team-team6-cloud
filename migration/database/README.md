# DB Migration Test Environment

EC2 MySQL → RDS MySQL 무중단 마이그레이션 테스트 환경

## Architecture

**단일 EC2 인스턴스**에 Nginx + Spring Boot + MySQL이 공존하는 환경에서 RDS로 마이그레이션

```
┌─────────────── EC2 Instance (단일) ───────────────┐
│                                                    │
│  ┌─────────┐                                       │
│  │  Nginx  │ ← 외부 트래픽 / K6 부하               │
│  │  :80    │                                       │
│  └────┬────┘                                       │
│       │                                            │
│       ├──────────────────┬─────────────────┐       │
│       ▼                  ▼                 │       │
│  ┌─────────┐       ┌─────────┐             │       │
│  │ Spring  │       │ Spring  │             │       │
│  │ :8080   │       │ :8081   │  ← 전환 후  │       │
│  │(로컬DB) │       │ (RDS)   │             │       │
│  └────┬────┘       └────┬────┘             │       │
│       │                 │                  │       │
│       ▼                 │                  │       │
│  ┌─────────┐            │                  │       │
│  │ MySQL   │            │                  │       │
│  │ :3306   │ ─ Replication ─┐              │       │
│  └─────────┘                │              │       │
└─────────────────────────────┼──────────────┘       │
                              ▼                      │
                    ┌─────── RDS MySQL ──────┐       │
                    │   (마이그레이션 타겟)   │       │
                    └────────────────────────┘       │
```

**전환 방식**: Nginx upstream을 `:8080` → `:8081`로 변경 (앱 재시작 불필요)

## Directory Structure

```
migration/database/
├── migration-plan.md              # 마이그레이션 계획서
├── README.md                      # 이 파일
│
├── load-generator/                # 부하 생성 (별도 서버 또는 로컬)
│   ├── docker-compose.yml         # K6 only (메트릭은 monitoring-server InfluxDB로 전송)
│   ├── .env.example               # K6 표준 환경변수 템플릿
│   └── k6/
│       ├── config.js              # 설정 (URL, QPS, 임계치)
│       ├── load-test.js           # 메인 부하 테스트 (300 QPS)
│       ├── warmup.js              # 커넥션 풀 워밍업 (GET만!)
│       ├── cutover-monitor.js     # 전환 중 다운타임 정밀 측정
│       └── results/               # 테스트 결과 저장
│
├── source-server/                 # EC2 서버에 배포할 파일들
│   ├── scripts/
│   │   ├── setup-replication.sh   # 복제 설정 (GTID/binlog 자동 선택)
│   │   ├── check-lag.sh           # 복제 지연 모니터링
│   │   ├── cutover.sh             # 전환 스크립트
│   │   ├── rollback.sh            # 롤백 스크립트
│   │   └── verify-data.sh         # 데이터 정합성 검증
│   ├── nginx/
│   │   ├── nginx.conf             # Nginx 설정
│   │   ├── upstream-source.conf   # :8080 라우팅 (전환 전/롤백)
│   │   └── upstream-target.conf   # :8081 라우팅 (전환 후)
│   └── exporters/
│       └── docker-compose.yml     # mysqld/nginx/node exporter
│
└── monitoring-server/             # 모니터링 서버 (별도 EC2)
    ├── docker-compose.yml         # Prometheus + Alertmanager + Grafana + InfluxDB + exporters
    ├── alertmanager/
    │   └── alertmanager.yml
    ├── prometheus/
    │   ├── prometheus.yml
    │   ├── blackbox.yml
    │   ├── alerts/migration-alerts.yml
    │   └── targets/               # source/probe 타겟 파일(file_sd)
    └── grafana/
        ├── provisioning/
        └── dashboards/migration-dashboard.json
```

## Rehearsal-First 운영 원칙

리허설 단계에서는 롤백/장애 시나리오보다 아래 항목을 우선순위로 둔다.

1. 관측 가능성 확보: cutover 전/중/후를 동일 대시보드에서 비교 가능해야 함
2. 테스트 재현성 확보: 동일 스크립트와 동일 env로 반복 실행 가능해야 함
3. 개선 루프 고정: 리허설 1회당 변경점 1개만 적용 후 재측정

표준 리허설 루프 문서: `rehearsal-standard.md`

## Quick Start

### 1. EC2 서버 설정 (Nginx + Spring Boot + MySQL)

```bash
# 스크립트 배포 및 권한 부여
scp -r source-server/* ec2-user@<ec2-ip>:~/migration/
ssh ec2-user@<ec2-ip>
chmod +x ~/migration/scripts/*.sh

# Nginx 설정 적용
sudo cp ~/migration/nginx/nginx.conf /etc/nginx/nginx.conf
sudo cp ~/migration/nginx/upstream-source.conf /etc/nginx/conf.d/upstream.conf
sudo nginx -t && sudo nginx -s reload

# Exporter 실행 (모니터링용)
cd ~/migration/exporters
MYSQL_PASSWORD=<password> docker-compose up -d

# :8081 포트로 RDS 연결 앱 추가 실행
# (별도 프로파일 또는 환경변수로 RDS 연결 설정)
java -jar app.jar --server.port=8081 --spring.datasource.url=jdbc:mysql://<rds-endpoint>:3306/billage &
```

### 2. 복제 설정

```bash
# EC2에서 실행
export SOURCE_PASSWORD=<mysql-password>
export TARGET_HOST=<rds-endpoint>
export TARGET_PASSWORD=<rds-password>

./migration/scripts/setup-replication.sh

# Lag 모니터링 (별도 터미널)
TARGET_HOST=<rds-endpoint> TARGET_PASSWORD=<rds-password> ./migration/scripts/check-lag.sh
```

### 3. Load Generator 설정 (별도 서버 또는 로컬)

```bash
cd load-generator

# 표준 템플릿 복사 후 값 수정
cp .env.example .env
# 필수: K6_OUT=influxdb=http://<monitoring-private-ip>:8086/k6

# 실행
docker-compose up -d
```

### 4. Monitoring Server 설정 (별도 EC2)

```bash
cd monitoring-server

# 1) source exporter 타겟 등록
# prometheus/targets/mysql-source.yml
# prometheus/targets/node-source.yml
# prometheus/targets/nginx-source.yml
#
# 2) blackbox probe 타겟 등록
# prometheus/targets/probe-targets.yml
#
# 3) .env 준비 (RDS exporter/Grafana CloudWatch)
cp .env.example .env

# 실행
docker-compose up -d

# Grafana 접속: http://<monitoring-server-ip>:3000 (admin/admin)
# Alertmanager: http://<monitoring-server-ip>:9093
```

## Test Workflow

### Phase 1: Baseline 측정
```bash
# Load Generator에서
docker exec -it k6-load-tester k6 run \
  -e TARGET_URL=http://<ec2-ip> \
  --duration 10m \
  /scripts/load-test.js
```

### Phase 2: 복제 중 부하 테스트
```bash
# 복제 진행 중 상태에서 동일한 부하 테스트 실행
# Grafana에서 Replication Lag 모니터링
```

### Phase 3: Cutover

```bash
# 1. Warmup - ⚠️ GET 요청만! (쓰기 절대 금지)
docker exec -it k6-load-tester k6 run \
  -e WARMUP_TARGET_URL=http://<ec2-ip>:8081 \
  /scripts/warmup.js

# 2. Cutover 모니터링 시작 (별도 터미널)
docker exec -it k6-load-tester k6 run \
  -e TARGET_URL=http://<ec2-ip> \
  /scripts/cutover-monitor.js

# 3. Cutover 실행 (EC2에서)
export SOURCE_PASSWORD=<mysql-password>
export TARGET_HOST=<rds-endpoint>
export TARGET_PASSWORD=<rds-password>

./migration/scripts/cutover.sh
```

### Phase 4: 검증
```bash
# EC2에서
./migration/scripts/verify-data.sh
```

### Rollback (필요시)
```bash
# EC2에서
./migration/scripts/rollback.sh
```

## 허용 기준

| 항목 | 기준 |
|------|------|
| 최대 다운타임 | ≤ 3초 |
| 에러율 | ≤ 0.1% |
| 데이터 유실 | 0건 |
| p95 Latency | < 500ms |

## 주의사항

### Warmup은 GET 요청만 수행

```
Warmup 시 쓰기 요청(POST/PUT/DELETE) 금지

이유:
- RDS는 아직 replica 상태
- 쓰기 시 Source와 데이터 불일치 발생
- warmup.js는 GET 요청만 수행하도록 구현됨
```

### GTID vs Binlog Position

```bash
# setup-replication.sh가 자동으로 감지
# GTID 모드 ON → GTID 기반 복제 (권장)
# GTID 모드 OFF → binlog position 기반 복제
```

## Monitoring URLs

| Service | URL | 비고 |
|---------|-----|------|
| Grafana | http://<monitoring-ip>:3000 | admin/admin |
| Prometheus | http://<monitoring-ip>:9090 | |
| InfluxDB | http://<monitoring-ip>:8086 | K6 메트릭 수집 |
| Alertmanager | http://<monitoring-ip>:9093 | 알람 집계 |
| Blackbox Exporter | http://<monitoring-ip>:9115 | synthetic probe |

## Troubleshooting

### Replication Lag이 높을 때
1. Source DB 부하 확인 (`SHOW PROCESSLIST`)
2. 네트워크 대역폭 확인
3. RDS 인스턴스 사이즈 확인

### K6 Connection Refused
1. Security Group 확인 (Load Generator → EC2 :80)
2. Nginx 상태: `sudo nginx -t && sudo systemctl status nginx`
3. Spring Boot 앱 상태: `curl http://localhost:8080/actuator/health`

### Cutover 후 5xx 에러
1. :8081 앱 상태 확인: `curl http://localhost:8081/actuator/health`
2. RDS 커넥션 수 확인
3. HikariCP 로그 확인

### Warmup 중 쓰기 에러
1. warmup.js가 GET만 수행하는지 확인
2. 실수로 load-test.js를 :8081에 실행하지 않았는지 확인
