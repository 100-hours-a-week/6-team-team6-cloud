# Billage 마이그레이션 계획서 (v1 → v2)

## 1. 문서 개요 및 목적

이 문서는 Billage 렌탈 플랫폼의 인프라를 현대적인 클라우드 아키텍처로 전환하기 위한 **마스터 마이그레이션 플랜**입니다.

**목적:**
- 단일 EC2 인스턴스 기반의 모놀리식 배포 구조를 마이크로서비스 친화적인 다중 인스턴스 아키텍처로 전환
- 자동 스케일링, 고가용성, 무중단 배포 능력 확보
- 운영 복잡도 증가에도 불구하고 배포 안정성과 속도 향상
- Senior DevOps 엔지니어의 검토 및 승인을 거쳐 실행

**범위:**
- 네트워킹: VPC 레이아웃, 서브넷, 보안 그룹 구성
- 컴퓨팅: EC2 → ASG 전환, Launch Template 설계
- 데이터: MySQL v1 → RDS 마이그레이션 (JWT 기반 stateless 아키텍처)
- 메시징: 로컬 메시지 브로커 → RabbitMQ 전환 (분산 채팅 지원)
- CI/CD: GitHub Actions OIDC → ECR → ASG 파이프라인
- 모니터링: CloudWatch 기반 알람 유지 및 강화
- 리스크 관리: 롤백 전략, 검증 기준, 이중 실행(dual-run) 기간 관리

---

## 2. 프로젝트 배경: 왜 마이그레이션이 필요한가?

### 2.1 현재 상태(v1)의 문제점

#### 단일 장애점(Single Point of Failure)
- **문제:** 각 환경(Dev/Prod)마다 t4g.medium 단일 인스턴스에서 모든 서비스(Backend, Frontend, AI) 실행
  - 인스턴스 고장 → 즉시 전체 플랫폼 다운(RTO ≈ 10분 이상, RPO = 데이터 손실 가능성)
  - OS 패치/커널 업데이트 → 강제 재부팅 → 서비스 중단 (제로-다운타임 배포 불가)
  - 단일 MySQL 프로세스 고장 → 모든 서비스 데이터베이스 연결 실패

#### 스케일링 한계
- **문제:** 단일 인스턴스로는 트래픽 증가 시 수평 확장 불가능
  - CPU 병목(t4g.medium = 2 vCPU) → 동시 사용자 수 증가 시 응답 시간 급증
  - 메모리 부족(4GB) → OOM Kill으로 인한 예측 불가능한 서비스 재시작
  - v1은 500 MAU 규모로 설계됨 → 300K MAU 성장을 지원 불가
- 수직 확장(t4g.large로 업그레이드)만 가능 → 비용 증가, 유연성 부족
  - 각 서비스의 독립적 스케일링 불가능 (Backend 트래픽 높아도 Frontend/AI도 함께 확장)

#### 배포 프로세스의 취약성
- **문제:** SCP + SSH + systemd 재시작 기반 배포
  - 배포 중 수초~수십 초의 다운타임 발생 (Blue-Green 시도했으나 포트 전환 시 connection reset)
  - 배포 실패 시 수동 롤백 필요 (자동화 불가)
  - 배포 중 동시 접속 세션 손실 (Next.js PM2 재시작 → 브라우저 연결 끊김)
  - 부분 배포 불가능 (Backend 업데이트 시 Frontend도 함께 영향)

#### 데이터베이스 운영의 위험
- **문제:** 인스턴스 내 MySQL 직접 호스팅
  - 자동 백업 미흡 → 실수로 DROP TABLE 했을 때 복구 곤란
  - 리플리케이션 없음 → 데이터 중복성 제로
  - 스토리지 한계 → 현재 20GB 설정, 초과 시 즉시 디스크 풀 상태
  - 패치/업그레이드 → 마이그레이션 윈도우 필요
  - 접근 제어 기초적 (OS-level 방화벽만 의존)

#### 모니터링/알림의 한계
- **문제:** CloudWatch 기반이나 단일 지표 중심
  - CPU/StatusCheck 외 상세한 애플리케이션 메트릭 부족
  - 알림 → SNS → Lambda → Discord로 지연이 크고 신뢰성 낮음
  - 로그 수집 미흡 (Loki는 Management VPC에만 있고, 애플리케이션 로그는 파일 기반)
  - 성능 분석 곤란 (응답 시간, DB 쿼리 분석, 캐시 히트율 등 가시성 부족)

#### 보안 및 규정
- **문제:** 공개 서브넷에만 배치, 제한적인 네트워크 분리
  - RDS 미도입 → MySQL 자격증명이 인스턴스 내 평문(systemd env) 저장 위험
  - 환경 변수 관리 미흡 → 보안 감사 취약성
  - WireGuard VPN 기반이나 Dev/Prod 분리 미흡 (네트워크 레벨)

### 2.2 마이그레이션의 기대 효과

| 구분 | v1 현재 | v2 목표 | 기대도 |
|------|--------|--------|--------|
| **RTO** | ~10분 | <1분 (ASG 자동 재시작) | 매우 높음 |
| **RPO** | 수 시간 | <1시간 (RDS 자동 백업) | 높음 |
| **배포 다운타임** | 10초~1분 | 0초 (무중단) | 매우 높음 |
| **배포 시간** | 5분~10분 | 2분~3분 | 높음 |
| **확장 능력** | 불가 | 자동/수동 모두 가능 | 매우 높음 |
| **비용 효율성** | 낮음 (수직확장) | 높음 (수평확장) | 중간 |
| **운영 복잡도** | 낮음 | 높음 | 중간 |

---

## 3. 현재 아키텍처 상세 분석 (v1 AS-IS)

### 3.1 네트워크 계층

**VPC 구성:**
- **Dev:** 10.0.0.0/16 (공개 서브넷 10.0.1.0/24, AZ: ap-northeast-2a)
- **Prod:** 10.1.0.0/16 (공개 서브넷 10.1.1.0/24, AZ: ap-northeast-2a)
- **Management:** 10.2.0.0/16 (Prometheus, Grafana, Loki 호스팅)

**문제점:**
- 단일 AZ 배치 → AZ 다운 시 서비스 전체 장애
- 공개 서브넷에만 배치 → NAT Gateway 없음 → 인바운드만 노출
- 사설 서브넷 부재 → RDS, ElastiCache 배치 불가능

### 3.2 컴퓨팅 계층

**인스턴스 사양:**
- **타입:** t4g.medium (ARM64, 2 vCPU, 4GB RAM)
- **OS:** Ubuntu 24.04 (focal → jammy 마이너 버전 유지)

**서비스 배치:**
```
┌─────────────────────────────────────────────────────────┐
│  EC2 단일 인스턴스 (t4g.medium, 10.0.1.x)              │
├─────────────────────────────────────────────────────────┤
│ Nginx (Port 80/443, WildCard Cert 미적용)            │
│  ├─ /api/* → localhost:8080 (Spring Boot Backend)    │
│  ├─ /ai/*  → localhost:5000 (FastAPI AI)             │
│  └─ /*     → localhost:3000 (Next.js Frontend)       │
│                                                        │
│ Spring Boot Backend (Port 8080/8081)                 │
│  ├─ systemd service: billage-backend                 │
│  ├─ Blue-Green: 포트 8080 ↔ 8081 전환              │
│  ├─ DB: MySQL localhost:3306                         │
│  └─ S3: presigned-url 업로드                         │
│                                                        │
│ FastAPI AI (Port 5000)                               │
│  ├─ systemd service: billage-ai                      │
│  ├─ Docker 컨테이너 (로컬 레지스트리)               │
│  └─ Redis 미사용 (채팅 기능 준비)                    │
│                                                        │
│ Next.js Frontend (Port 3000)                         │
│  ├─ PM2 프로세스 매니저                              │
│  ├─ SSR 모드 (4 워커 스레드)                          │
│  └─ systemd service: billage-frontend               │
│                                                        │
│ MySQL (Port 3306, localhost)                         │
│  ├─ 데이터 저장소 (/var/lib/mysql)                   │
│  ├─ 스토리지: 20GB (자동 증가 미설정)               │
│  ├─ 레플리케이션: 없음                               │
│  ├─ 백업: 크론 스크립트 (매 6시간, S3 업로드)      │
│  └─ 문자집합: utf8mb4                                │
│                                                        │
│ 기타:                                                 │
│  ├─ WireGuard VPN (VPN 클라이언트 전용)            │
│  ├─ CloudWatch Agent (메트릭 수집)                  │
│  └─ SSH (Port 22, bastion 없이 직접 접근)          │
└─────────────────────────────────────────────────────────┘
```

**systemd 서비스:**
- `billage-backend.service` → Spring Boot JAR 직실행
- `billage-ai.service` → Docker 컨테이너 (`docker run ...`)
- `billage-frontend.service` → PM2 프로세스 관리 (`pm2 start ecosystem.config.js`)

**배포 프로세스 (v1):**
1. GitHub Actions: Maven build → JAR 생성 (Backend)
2. npm build (Frontend)
3. SCP를 통해 아티팩트 원격 서버에 복사
4. SSH를 통해 systemd 재시작 명령 실행
5. Systemd: 이전 프로세스 stop → 신규 JAR 실행
6. 재시작 중 10초~1분 다운타임 발생

**문제점:**
- 배포 중 connection draining 미지원 → 클라이언트 요청 손실
- 롤백 프로세스: 이전 JAR 수동 복구 필요
- 배포 트랜잭션성 없음 (3개 서비스 동시 배포 시 불완전한 상태 가능)

### 3.3 저장소 계층

**MySQL (인스턴스 호스팅):**
- 데이터 저장소: `/var/lib/mysql` (인스턴스 EBS 볼륨)
- 백업: S3 크론 백업 (매 6시간, 7일 보관)
- 복구 시간: 수동 복구, ~30분 이상 소요
- 용량: 현재 8GB 사용 중, 20GB 총 용량 (증가 계획 미흡)

**S3 (이미지 저장):**
- 버킷: billage-images-dev, billage-images-prod
- 업로드: Presigned URL 방식
- 라이프사이클: 30일 후 자동 삭제 미설정

**세션 저장:**
- MySQL 기반 (spring-session 사용)
- 분산 세션 미지원 → 인스턴스 재시작 → 사용자 재로그인 필요

### 3.4 보안/접근 제어

**IAM:**
- EC2 Role: `Billage-EC2-Role`
  - S3 접근 (billage-images-dev, billage-images-prod)
  - SSM Parameter Store 접근 (SecureString)
  - CloudWatch Logs 업로드
  - ECR 미도입 (로컬 Docker 레지스트리)

**환경 변수 저장:**
- SSM Parameter Store (SecureString + KMS)
- 자격증명: `/billage/dev/db-password`, `/billage/dev/jwt-secret` 등
- 참조: systemd 시작 시 `systemctl set-environment` 또는 `.env` 파일

**네트워크 보안:**
- WireGuard VPN (역할별 IP 할당)
  - DevOps: 10.100.0.16/28
  - Backend팀: 10.100.0.32/28
  - Frontend팀: 10.100.0.48/28
  - AI/ML팀: 10.100.0.64/28
- Security Group: 단순 (SSH, Nginx 포트만)

**SSL/TLS:**
- 와일드카드 인증서: billages.com (미적용)
- 현재 자체 서명 인증서(self-signed)

### 3.5 모니터링/알림

**CloudWatch 메트릭:**
- EC2: CPU, StatusCheck (1분 주기)
- 알람: CPU > 80% → SNS → Lambda → Discord
- 로그: `/var/log/syslog`, 애플리케이션 로그 (파일 기반)

**Management VPC 모니터링:**
- Prometheus: 10.2.0.0/16 내 호스팅 (VPC Peering 연결)
- Grafana: 대시보드 (Dev/Prod 분리)
- Loki: 로그 수집 (선택적)

**문제점:**
- 애플리케이션 메트릭 부족 (응답 시간, 에러율, DB 쿼리 분석)
- 분산 추적(Distributed Tracing) 없음
- 로그 중앙화 미흡 (개별 서버 로그 기반)

---

## 4. 목표 아키텍처 상세 분석 (v2 TO-BE)

### 4.1 네트워크 계층 (재설계)

**VPC 구성 (동일):**
- **Dev:** 10.0.0.0/16
- **Prod:** 10.1.0.0/16
- **Management:** 10.2.0.0/16

**새로운 서브넷 구조 (Dev 예시):**

```
Dev VPC (10.0.0.0/16)
├─ Public Subnet 1 (10.0.0.0/24, ap-northeast-2a)
│  └─ NAT Gateway (EIP 할당)
│  └─ ALB (보안 그룹: ALB-SG)
├─ Public Subnet 2 (10.0.1.0/24, ap-northeast-2c)
│  └─ NAT Gateway (EIP 할당)
│  └─ ALB (보안 그룹: ALB-SG)
├─ Private Subnet 1 - WAS (10.0.10.0/24, ap-northeast-2a)
│  └─ Backend ASG (t4g.small, 1-6)
│  └─ Frontend ASG (t4g.small, 1-3)
│  └─ AI ASG (t4g.small, 1-2)
│  └─ Security Group: Backend-SG, Frontend-SG, AI-SG
├─ Private Subnet 2 - WAS (10.0.11.0/24, ap-northeast-2c)
│  └─ Backend ASG (t4g.small, 1-6)
│  └─ Frontend ASG (t4g.small, 1-3)
│  └─ AI ASG (t4g.small, 1-2)
├─ Private Subnet 3 - DB (10.0.20.0/24, ap-northeast-2a)
│  └─ RDS MySQL Primary (db.t4g.micro, Multi-AZ)
│  └─ Security Group: RDS-SG
├─ Private Subnet 4 - DB (10.0.21.0/24, ap-northeast-2c)
│  └─ RDS MySQL Standby (자동 페일오버)
│  └─ RabbitMQ (Amazon MQ 또는 EC2, STOMP over WebSocket)
│  └─ Security Group: RDS-SG, RabbitMQ-SG
└─ VPC Endpoint (S3, ECR, Secrets Manager, SSM)
```

**왜 이렇게 설계했는가?**
- **2 AZ 분산:** AZ 다운 시에도 서비스 계속 운영 (RTO < 1분)
- **공개/사설 분리:** 인스턴스는 사설 서브넷에 → 더 강한 보안
- **NAT Gateway:** 사설 인스턴스가 외부(ECR, S3)와 통신 가능
- **DB/MQ 사설:** RDS, RabbitMQ는 공개 접근 차단 (인스턴스만 접근 가능)
- **VPC Endpoint:** NAT Gateway 경유하지 않고 AWS 내부 경로로 S3, ECR 접근 → 비용 절감

### 4.2 컴퓨팅 계층 (재설계)

**새로운 구조:**

```
┌─────────────────────────────────────────────────────────────┐
│  ALB (Application Load Balancer)                           │
│  ├─ Listener 80 (443 미설정)                              │
│  ├─ Target Group 1: Backend (Port 8080)                  │
│  ├─ Target Group 2: Frontend (Port 3000)                │
│  └─ Target Group 3: AI (Port 5000)                       │
│                                                            │
│  Routing Rule:                                            │
│  ├─ /api/* → Backend TG                                  │
│  ├─ /ai/*  → AI TG                                       │
│  └─ /* (default) → Frontend TG                           │
└─────────────────────────────────────────────────────────────┘
            ↓
┌─────────────────────────────────────────────────────────────┐
│  Backend ASG (min: 1, max: 6, desired: 2)                 │
│  ├─ Instance Type: t4g.small (2 vCPU, 2GB RAM)          │
│  ├─ Launch Template: billage-backend-lt                 │
│  ├─ Docker Image: billage-be:latest (ECR)              │
│  ├─ Health Check: /actuator/health (8080)              │
│  ├─ Scaling Policy: CPU > 70% (scale-up)              │
│  └─ Update Policy: Instance Refresh (무중단)           │
├─────────────────────────────────────────────────────────────┤
│  Frontend ASG (min: 1, max: 3, desired: 1)               │
│  ├─ Instance Type: t4g.small (2 vCPU, 2GB RAM)          │
│  ├─ Launch Template: billage-frontend-lt                │
│  ├─ Docker Image: billage-fe:latest (ECR)              │
│  ├─ Health Check: / (3000)                              │
│  └─ Scaling Policy: CPU > 75% (scale-up)               │
├─────────────────────────────────────────────────────────────┤
│  AI ASG (min: 1, max: 2, desired: 1)                     │
│  ├─ Instance Type: t4g.small (2 vCPU, 2GB RAM)          │
│  ├─ Launch Template: billage-ai-lt                      │
│  ├─ Docker Image: billage-ai:latest (ECR)              │
│  ├─ Health Check: /health (5000)                        │
│  └─ Scaling Policy: CPU > 80% (scale-up)               │
└─────────────────────────────────────────────────────────────┘
```

**ASG 세부 설정:**

**Backend ASG (300K MAU 성장 대응):**
- Min: 2 (High Availability)
- Max: 6 (Peak: ~900 RPS, 300K MAU)
- Desired: 2 (평상시 2개 인스턴스, HA 구성)
- Health Check: ALB + ELB Classic (180초 Unhealthy 판정)
- Cooldown: 300초 (스케일링 이벤트 사이 대기)
- Termination Policy: OldestLaunchTemplate (신규 버전 우선 유지)
- 성능 모델: t4g.small 1개 인스턴스 = ~300 RPS 처리, 6개 인스턴스 = ~1800 RPS (900 RPS 목표치의 2배 여유)

**Frontend ASG:**
- Min: 1 (비용 절감, 단일 장애 허용 가능)
- Max: 3
- Desired: 1
- 세션 기반 라우팅 고려 → ALB sticky session 활성화 (쿠키 기반, AWSALB)

**AI ASG:**
- Min: 1
- Max: 2 (ML 모델 메모리 집약적)
- Desired: 1
- 장기 실행 요청 대응 → Deregistration delay: 300초

**Launch Template 구성:**

각 ASG마다 Launch Template 설정:
- **AMI:** Ubuntu 24.04 ARM64 (커스텀 AMI 또는 공식 AMI)
- **인스턴스 타입:** t4g.small (변경 가능성 → Flexible 설정)
- **EBS:** 30GB gp3, DeleteOnTermination: true, 암호화 활성화
- **IAM Role:** 각 서비스별 전용 역할
  - Backend: S3(images), RDS, RabbitMQ, CloudWatch, Secrets Manager 접근
  - Frontend: S3(images), CloudWatch 접근
  - AI: ECR, Secrets Manager, RDS 접근
- **Security Group:** 각 서비스별 전용 (ALB → Backend:8080, Frontend:3000, AI:5000)
- **User Data:**
  - ECR 로그인 (IAM 역할 기반 AWS CLI)
  - Secrets Manager에서 비밀값 조회 (DB 패스워드, API 키)
  - Docker pull & run (ECR 이미지)
  - systemd service 등록 (자동 재시작)
- **모니터링:** CloudWatch detailed monitoring 활성화

**Docker 이미지 구조 (ECR):**

```
ECR Repositories:
├─ billage-be:
│  ├─ latest → 최신 안정 버전
│  ├─ v2.0.1, v2.0.2, ... (immutable 태그)
│  └─ Lifecycle Policy: 최신 10개만 유지, 나머지 자동 삭제
├─ billage-fe:
│  ├─ latest
│  ├─ v2.0.1, v2.0.2, ...
│  └─ Lifecycle Policy: 최신 10개만 유지
└─ billage-ai:
   ├─ latest
   ├─ v2.0.1, v2.0.2, ...
   └─ Lifecycle Policy: 최신 10개만 유지
```

**배포 프로세스 (v2):**
1. GitHub push to main/dev
2. GitHub Actions: Docker build & push to ECR
3. GitHub Actions: Update Launch Template (신규 이미지 버전 참조)
4. GitHub Actions: ASG Instance Refresh 트리거
5. ASG: 무중단 배포 (기존 인스턴스 계속 서빙 → 신규 인스턴스 부팅 → 트래픽 점진적 전환 → 기존 인스턴스 종료)

### 4.3 저장소 계층 (재설계)

**RDS MySQL (300K MAU 성장 대응):**
- **엔진:** MySQL 8.0
- **인스턴스 타입:**
  - Dev: db.t4g.micro (초기, 비용 절감)
  - Prod: db.t4g.medium 이상 (300K MAU 성능 확보)
- **스토리지:**
  - 초기: 20GB gp3 (현재 데이터 규모)
  - 자동 증가: 20GB → 100GB까지 자동 확장 (300K MAU 데이터 10-30GB 성장 수용)
  - IOPS: 3000 (기본, 필요시 증가)
  - 처리량: 125 MB/s
- **Multi-AZ 배치:** Primary (10.0.20.0/24) + Standby (10.0.21.0/24)
  - 동기 레플리케이션 → RPO = 0 (데이터 손실 없음)
  - Failover 자동 → RTO < 1분
- **백업:**
  - 자동 백업: 7일 보관 (스냅샷)
  - 수동 스냅샷: 중요 변경 전
  - 복구 시간: 스냅샷에서 ~ 5분
- **문자집합:** utf8mb4 (이모지 지원)
- **파라미터 그룹:** 성능 튜닝 (max_connections 계산: 300K MAU → ~10K DAU, ~1K peak 동시 사용자 → 요청당 1-2 커넥션 = 최소 300개 필요)
- **접근 제어:**
  - Security Group (RDS-SG): Backend, Frontend, AI ASG의 사설 IP 범위만 허용
  - 비밀번호: Secrets Manager 관리 (자동 로테이션 가능)

**RabbitMQ (분산 메시지 브로커):**
- **엔진:** RabbitMQ 3.12+ (또는 Amazon MQ 관리형)
- **배포:** Amazon MQ 또는 EC2 단일 인스턴스 (초기 단순성 위해)
- **용도:** 로컬 메시지 브로커 (Spring Simple Broker) → 외부 메시지 브로커 전환
  - STOMP over WebSocket (실시간 채팅 메시지 브로드캐스트)
  - 여러 서버가 동일한 메시지 채널 공유 (stateless 아키텍처)
- **구성:**
  - Virtual Host: `/billage`
  - 큐/토픽: 채팅 룸별 주제 (topic-based exchange)
  - Prefetch: 32 (메시지 처리량 조절)
- **WebSocket 동시 연결:** 300-500개 at peak (300K MAU)
- **접근 제어:** Security Group (RabbitMQ-SG), 사용자 인증 (Secrets Manager)
- **백업:** 설정 코드화 (Infrastructure as Code)

**Redis (캐싱, 향후 검토):**
- **현재:** 마이그레이션 범위에 포함되지 않음
- **이유:** JWT 기반 stateless 인증 + RabbitMQ로 메시지 처리 → 외부 세션 저장소 불필요
- **향후:** 300K MAU 이후 성능 최적화로 cache layer 추가 검토
- **후보:** ElastiCache Redis (cache.t4g.micro, 세션/객체 캐싱)

**S3 (기존 유지, 개선):**
- 버킷: billage-images-dev, billage-images-prod
- 업로드: Presigned URL (v1 동일)
- 라이프사이클: 90일 후 Glacier, 180일 후 삭제
- VPC Endpoint: S3 Gateway Endpoint (NAT 비용 절감)
- 암호화: AES-256 (기본)

**인증 방식 (개선):**
- JWT (JSON Web Token) 기반 stateless 인증 (v2.0.0부터)
  - 이점: 서버에서 세션 상태 유지 불필요 → 모든 인스턴스 동일하게 처리
  - 클러스터 확장성 매우 높음 (세션 친화성 불필요, Sticky Session 미필요)
  - 인스턴스 재시작 시에도 토큰 유효하면 재로그인 불필요
  - 모든 요청에 JWT 헤더 포함 (Authorization: Bearer &lt;token&gt;)

### 4.4 배포 및 CI/CD 파이프라인

**GitHub Actions OIDC 설정:**

```
GitHub Actions
  ↓
  ├─ Build Docker Image
  ├─ Push to ECR (OIDC → IAM Role)
  ├─ Update Launch Template (new image URI)
  ├─ Trigger ASG Instance Refresh
  ├─ Wait for healthy instances
  └─ Smoke test (health check endpoints)
```

**OIDC Trust Relationship:**
- GitHub 액션이 AWS STS 토큰 획득 (임시 자격증명)
- IAM Role 가정 → ECR push, Launch Template update 권한 부여

**배포 흐름 (상세):**

1. **Build Phase (5분)**
   - Maven: Spring Boot JAR 빌드
   - npm: Next.js 정적 파일 빌드
   - Docker build: 각 이미지 빌드

2. **Push Phase (2분)**
   - ECR 로그인 (OIDC)
   - Docker push: billage-be:v2.0.5, billage-fe:v2.0.5, billage-ai:v2.0.5
   - ECR에 태그 지정: latest → v2.0.5 업데이트

3. **Update Phase (1분)**
   - Launch Template 신규 버전 생성 (새로운 이미지 URI)
   - ASG: Launch Template 버전 업데이트

4. **Refresh Phase (5~10분)**
   - ASG Instance Refresh 시작
   - 기존 인스턴스: 트래픽 유지, 신규 요청 수락 안함 (connection draining)
   - 신규 인스턴스: 부팅 → 헬스 체크 통과 → 트래픽 수락
   - 순차적 종료: 기존 인스턴스 → Deregistration delay (300초) → 종료

5. **Validation Phase (2분)**
   - Smoke test: /api/health, /ai/health, / 엔드포인트 확인
   - 로그 모니터링: 에러율, 응답 시간 확인
   - 알람 상태: CloudWatch 알람 정상 여부 확인

**롤백 절차:**

만약 배포 후 문제 발생:
1. GitHub Actions: 이전 이미지 태그로 ASG Instance Refresh 재시작
2. 또는 수동: Launch Template 이전 버전으로 복구 → ASG 재갱신
3. RTO: ~5분 (이미지 풀 + 인스턴스 부팅)

### 4.5 보안/접근 제어 (강화)

**IAM Role (세분화):**

```
Backend EC2 Role:
├─ ECR: 이미지 pull 권한
├─ S3: billage-images-* 버킷 write 권한
├─ RDS: 데이터베이스 접근 (Security Group 기반)
├─ RabbitMQ: 접근 불필요 (Security Group + 비밀번호 기반)
├─ Secrets Manager: DB 비밀번호, JWT 키, RabbitMQ 비밀번호 read
├─ CloudWatch: Logs, Metrics 업로드
└─ SSM: Parameter 읽기 (선택적)

Frontend EC2 Role:
├─ ECR: 이미지 pull 권한
├─ S3: billage-images-* 버킷 read 권한
├─ Secrets Manager: 필요시 (현재 불필요)
└─ CloudWatch: Logs, Metrics 업로드

AI EC2 Role:
├─ ECR: 이미지 pull 권한
├─ RDS: 모델 저장소 접근 (선택적)
├─ Secrets Manager: API 키 read
└─ CloudWatch: Logs, Metrics 업로드
```

**Security Group (세분화):**

```
ALB Security Group:
├─ Inbound: 0.0.0.0/0 포트 80 (HTTP)
├─ Inbound: 0.0.0.0/0 포트 443 (HTTPS, 미설정)
└─ Outbound: 모든 포트 (Backend, Frontend, AI로)

Backend Security Group:
├─ Inbound: ALB-SG 포트 8080
├─ Outbound: RDS-SG 포트 3306 (MySQL)
├─ Outbound: RabbitMQ-SG 포트 5672 (AMQP 메시지 브로커)
└─ Outbound: 0.0.0.0/0 포트 443 (외부 API, S3, ECR)

Frontend Security Group:
├─ Inbound: ALB-SG 포트 3000
└─ Outbound: Backend-SG 포트 8080 (SSR 중 API 호출)

AI Security Group:
├─ Inbound: ALB-SG 포트 5000
└─ Outbound: RDS-SG 포트 3306 (모델 데이터 조회)

RDS Security Group:
└─ Inbound: Backend-SG, Frontend-SG, AI-SG 포트 3306

RabbitMQ Security Group:
└─ Inbound: Backend-SG 포트 5672 (AMQP), 포트 15672 (관리 UI, 내부 전용)
```

**TLS/SSL (미적용, 향후 개선):**
- ACM 인증서: wildcard *.billages.com
- ALB Listener: 443 추가 예정
- HSTS, 리다이렉트 설정

**환경 변수 관리:**
- Secrets Manager에 이동 (SSM Parameter Store 대신)
  - 비밀번호: 자동 로테이션 가능
  - 감사 로깅: CloudTrail
  - 버전 관리: 자동
- Launch Template User Data에서 fetch하여 환경 변수로 설정

### 4.6 모니터링/알림 (강화)

**CloudWatch 메트릭 (확장):**
- **ALB:** 요청 수, 응답 시간, HTTP 4xx/5xx 비율
- **ASG:** 인스턴스 수, CPU, 메모리, 네트워크
- **RDS:** CPU, 메모리, 연결 수, 쿼리 지연, IOPS
- **ElastiCache:** CPU, 메모리, 연결 수, 캐시 히트율
- **애플리케이션 (Custom Metrics):**
  - Spring Boot: 요청 처리 시간, 에러율 (Micrometer)
  - Next.js: 페이지 렌더링 시간, TTFB
  - FastAPI: 모델 추론 시간, GPU 메모리

**대시보드 (Grafana/CloudWatch):**
- 시스템 대시보드: ALB, ASG, RDS, Redis 상태
- 애플리케이션 대시보드: 에러율, 응답 시간, 처리량
- 비즈니스 대시보드: 활성 사용자, 예약 건수, 수익

**알람 규칙:**
- ALB HTTP 5xx > 1% (1분 평균) → 심각
- RDS CPU > 80% (5분 평균) → 경고
- ASG 인스턴스 Unhealthy → 심각
- Redis 메모리 > 80% → 경고
- 배포 중 에러율 급증 → 롤백 트리거

**로그 집중화:**
- CloudWatch Logs: /billage/backend, /billage/frontend, /billage/ai
- Loki (Management VPC): 저비용 장기 보관
- Log Insights: 쿼리 분석

---

## 5. 마이그레이션 전략: 왜 Strangler Fig를 선택했나?

### 5.1 고려한 전략들

#### Option A: Big Bang (한 번에 완전 전환)
**프로세스:**
- v1 전체 서비스 중단
- v2로 완전 전환
- 복구 후 v1 삭제

**장점:**
- 구현 단순함
- 테스트 기간 짧음
- 운영 이중화 비용 없음

**단점:** ⚠️ 위험
- 롤백 시간: 30분 이상
- 예상 못한 버그 → 전체 서비스 다운
- 데이터 검증 불가능 (마이그레이션 후 발견 시 복구 곤란)
- 사용자 영향: 30분~2시간 서비스 이용 불가능
- Billage는 예약 기반 비즈니스 → 취소 요청, 수익 손실

**결정:** ❌ 부적절 (너무 위험)

#### Option B: Rolling Blue-Green (단계별 전환)
**프로세스:**
- v1 인스턴스 유지하며, v2 신규 인스턴스 구축
- 특정 시점에 로드 밸런서 DNS 전환
- 롤백: 이전 DNS로 복구

**장점:**
- 롤백 빠름 (DNS 캐시 고려하면 ~5분)
- 사전 검증 가능
- 서비스 중단 최소

**단점:**
- 데이터 마이그레이션 기간 중 데이터 불일치 가능성
  - v1 MySQL ↔ v2 RDS 간 동기화 필요
  - 도중 사용자 예약/결제 생성 → v1, v2 중 어디에 저장?
- 세션 문제: v1 세션 관리 ↔ v2 JWT stateless 호환 확인 필요
- 부분 배포 불가능 (Backend만 먼저 이동 불가)

**결정:** ⚠️ 부분 적용 (API 검증, 데이터 마이그레이션 이후)

#### Option C: Strangler Fig (점진적 요청 대체)
**프로세스:**
1. v2 인프라 구축 (병렬)
2. 신규 요청만 v2로 라우팅 (특정 비율 %)
3. 기존 요청은 v1 유지
4. 점진적으로 비율 증가 (10% → 50% → 100%)
5. 데이터 검증 후 v1 폐기

**장점:**
- 위험 최소화 (문제 발생 시 즉시 v1로 복구)
- 사용자 영향 없음 (일부만 v2 경험)
- 실제 트래픽으로 v2 성능 검증 가능
- 롤백 간단 (traffic weight 조정만)
- 세션/데이터 검증 기간 충분

**단점:**
- 구현 복잡 (traffic split logic)
- 두 버전 동시 운영 → 비용 증가 (일시적)
- 모니터링 복잡 (v1 vs v2 비교 필요)
- 마이그레이션 기간 길어짐 (2-3주)

**결정:** ✅ 최선 (Billage의 조건에 부합)

### 5.2 Strangler Fig 적용 방법 (Billage)

**Route 53 Weighted Routing으로 구현:**

```
Route 53 Policy:
dev.billages.com
├─ Weight 100 (v1 EIP) → v1 EC2
├─ Weight 0 (v2 ALB DNS) → v2 ALB
└─ 단계별 조정:
   ├─ Day 3: 100 / 0
   ├─ Day 5: 90 / 10 (v2 10% 트래픽)
   ├─ Day 7: 70 / 30
   ├─ Day 10: 50 / 50 (데이터 검증 집중)
   ├─ Day 14: 10 / 90
   └─ Day 16: 0 / 100 (v2 전환 완료)
```

**Route 53 Health Check:**
- v1 EIP: EC2 상태 체크
- v2 ALB: ALB 대상 그룹 체크
- 장애 시 자동으로 트래픽 전환

**모니터링 필수:**

| 지표 | v1 | v2 | 판단 기준 |
|------|----|----|----------|
| 응답 시간 (P95) | < 200ms | < 200ms | 동등 성능 확보 |
| 에러율 | < 0.1% | < 0.1% | 안정성 확인 |
| 활성 세션 | v1 전체 | v2 비율% | 비례 증가 확인 |
| DB 쿼리 | v1 MySQL | v2 RDS | 지연 동등 확인 |

**데이터 검증 (Dual-Write, Dual-Read 불필요):**
- v1, v2는 다른 데이터베이스 사용
- 데이터 마이그레이션 도구로 사전 동기화
- Strangler 기간 중 v1 데이터만 수정 (v2는 읽기 캐시로 활용)
- 전환 후 다시 확인

---

## 6. 마이그레이션 순서 및 의존성

### 6.1 의존성 맵

```
Dependencies:
├─ v2 인프라 프로비저닝 (Terraform) [기반, 트래픽 0]
│  ├─ VPC, Subnets, NAT, SG
│  ├─ RDS MySQL
│  ├─ RabbitMQ (Amazon MQ 또는 EC2)
│  ├─ ALB + ASG (Target Group)
│  └─ ECR + CI/CD Pipeline
│
├─ Phase A: 외부 서비스 전환 (단일 인스턴스, v1에서) [리스크 낮음]
│  ├─ Step 1: Host MySQL → RDS 전환
│  └─ Step 2: 로컬 메시지 브로커 → RabbitMQ 전환
│     (이 시점에서 서버는 stateless)
│
├─ Phase B: v2 환경 검증 (트래픽 0, 내부 테스트) [리스크 낮음]
│  ├─ Docker CI/CD 파이프라인 검증
│  └─ 통합 테스트 + 부하 테스트 (100→300→900 QPS)
│
├─ Phase C: 트래픽 전환 [리스크 높음]
│  ├─ Route 53 Weighted Routing (5%→30%→80%→100%)
│  └─ 모니터링 + 롤백 대기
│
└─ Phase D: v1 정리 [리스크 없음]
   ├─ v1 인스턴스 종료
   └─ 리소스 삭제 + 회고
```

### 6.2 상세 순서 (Week 1-6)

**Phase A: 외부 서비스 전환 — "상태 제거" (Week 1-3)**

핵심 근거: 현재 단일 서버는 실시간 채팅을 위해 stateful한 서버이다. 트래픽 전환 전에 상태를 최대한 제거하고, 외부 서비스로 먼저 교체해야 한다.

Why?
- 상태를 유지하는 서버가 있는 채로 스케일 아웃하면, 채팅에서 실시간 메시지 교환 불가 (각 서버가 다른 구독 정보를 가짐)
- Sticky Session을 도입해도 채팅 구독 정보를 담고 있는 세션은 각 서버마다 다르므로 문제 발생
- DB를 먼저 분리하는 이유: 다중 서버가 각각 다른 DB를 바라보는 불상사 방지

**Step 1: DB → RDS 전환 (Week 1-2)**
- Host MySQL → RDS mysqldump + Replication
- Runbook 기반 리허설 완료 후 실행
- PNR: RDS 엔드포인트로 애플리케이션 전환 시점

**Step 2: 로컬 메시지 브로커 → RabbitMQ 전환 (Week 2-3)**
- Spring 내장 Simple Broker → RabbitMQ (STOMP over WebSocket)
- 애플리케이션 코드 수정 필요 (메시지 발행/구독 로직)
- 단일 인스턴스 상태에서 전환하므로 리스크 낮음

**Phase B: v2 환경 검증 (Week 3-4)**

v2 인프라는 이미 프로비저닝되어 있음. Docker CI/CD로 v2 환경에 앱 배포 후 검증.

- Docker 이미지 빌드 → ECR Push → ASG 배포 파이프라인 검증
- v2 환경에서 통합 테스트 (API + WebSocket + RabbitMQ + RDS 연동)
- 부하 테스트: 100 → 300 → 900 QPS
- Go/No-Go: 에러율 < 0.1%, p99 latency 기준 이내

**Phase C: 트래픽 전환 (Week 4-5)**

- Route 53 Weighted Routing: v1 100% → v2 5% → 30% → 80% → 100%
- 각 단계별 24시간 모니터링 후 다음 단계
- 문제 발생 시 즉시 v1으로 복구 (Route 53 weight 변경, ~1분)

**Phase D: v1 정리 (Week 5-6)**

- v1 인스턴스는 2주간 유지 (롤백 버퍼)
- v2 안정화 확인 후 v1 종료
- 불필요한 리소스 삭제, 마이그레이션 회고

### 6.3 왜 "상태 제거 → 트래픽 전환" 순서인가?

**가장 큰 변화점 4가지:**
1. 빅뱅 수작업 배포 → Docker 기반 CI/CD
2. 단일 서버 → 다중 서버 (ALB + ASG)
3. Host MySQL → RDS
4. 로컬 메시지 브로커 → 외부 메시지 브로커 (RabbitMQ)

현재 단일 서버는 채팅 구독 정보를 서버 메모리에 보관하는 stateful 서버이다.
이 상태로 다중 서버 구조로 전환하면:
- 유저 A(서버1)와 유저 B(서버2)가 같은 채팅방이지만 메시지 교환 불가
- Sticky Session으로도 해결 불가 (구독 정보 자체가 서버별로 다름)

따라서 트래픽 전환(스케일 아웃) 전에:
1. DB를 외부로 분리 → 모든 서버가 동일한 데이터 소스 사용 보장
2. 메시지 브로커를 외부로 분리 → 모든 서버가 동일한 메시지 채널 공유 보장
이 두 가지가 완료되면 서버는 stateless가 되어 안전하게 스케일 아웃 가능.

**왜 인프라 프로비저닝과 트래픽 전환을 분리하는가?**

v2 인프라를 미리 띄워두는 것과 트래픽을 전환하는 것은 별개의 작업이다.
- 프로비저닝: Terraform apply로 ALB, ASG, RDS, RabbitMQ 생성 → 트래픽 0, 리스크 없음
- 검증: v2 환경에 앱을 배포하고 부하 테스트 → 트래픽 0, 리스크 없음
- 전환: Route 53으로 점진적 트래픽 이동 → 여기가 유일한 리스크 구간

미리 프로비저닝해둔 인프라에서 충분히 검증한 후, 확신이 생기면 트래픽을 전환한다.

**리허설 vs Dev/Prod 전략이 다른 이유?**

- 리허설: 300 QPS 부하를 걸며 무중단 마이그레이션 가능 여부 + 다운타임 지표 측정
- Dev/Prod: 실제 사용자가 적으므로 점검 시간을 잡고 중단 배포로 한 번에 교체
  - v2 인프라 프로비저닝
  - 테스트 통과한 Docker CI/CD로 GitHub Actions 변경
  - v1 → v2로 한 번에 교체

---

## 7. 공통 사전 준비 사항

### 7.1 네트워킹 기반 (Week 1)

**항목:**
1. VPC 및 서브넷 생성
   - Dev VPC 서브넷 (공개 2개, 사설 4개)
   - Prod VPC 서브넷 (동일)
   - 라우팅 테이블 설정 (공개 → Internet Gateway, 사설 → NAT Gateway)

2. NAT Gateway 생성
   - 공개 서브넷 1, 2에 각각 배치 (HA)
   - EIP 할당 (고정 IP)

3. VPC Endpoint 생성
   - S3 Gateway Endpoint (NAT 비용 절감)
   - ECR API Endpoint (com.amazonaws.ap-northeast-2.ecr.api)
   - Secrets Manager Endpoint
   - SSM Parameter Store Endpoint

4. Security Group 사전 정의
   - ALB-SG, Backend-SG, Frontend-SG, AI-SG
   - RDS-SG, Redis-SG

**참조 문서:** 01-networking.md (상세 설정)

### 7.2 IAM 역할 및 정책 (Week 1)

**항목:**
1. EC2 인스턴스 IAM Role
   - Backend: ECR pull, S3, RDS, Redis, Secrets Manager, CloudWatch
   - Frontend: ECR pull, S3, CloudWatch
   - AI: ECR pull, RDS, Secrets Manager, CloudWatch

2. GitHub Actions OIDC 설정
   - IAM OIDC Provider 추가 (token.actions.githubusercontent.com)
   - IAM Role: ECR push, Launch Template update 권한
   - Trust Policy: GitHub 리포지토리 제한

3. Lambda 함수용 Role (알림 전송)
   - CloudWatch Logs 읽기
   - SNS 메시지 발행

**참조 문서:** 02-iam-oidc.md (상세 설정)

### 7.3 RDS MySQL 프로비저닝 (Week 1-2)

**항목:**
1. RDS 생성
   - 엔진: MySQL 8.0
   - 인스턴스: db.t4g.micro
   - Multi-AZ 활성화
   - 저장소: 20GB gp3 자동 증가 (50GB까지)

2. 파라미터 그룹 커스터마이징
   - max_connections: 300
   - query_cache_type: 0 (MySQL 8.0에서 deprecated)
   - slow_query_log: 1 (CloudWatch Logs로 전송)

3. Security Group 설정
   - Backend, Frontend, AI SG의 CIDR 범위에서만 접근 허용
   - 포트 3306

4. 백업 설정
   - 자동 백업: 7일 보관
   - 백업 시간: 03:00 UTC (한국 낮시간 피함)
   - 수동 스냅샷: 마이그레이션 전/후

**참조 문서:** 03-rds-mysql.md

### 7.4 RabbitMQ 프로비저닝 (Week 1-2)

**항목:**
1. RabbitMQ 배포 (Amazon MQ 또는 EC2)
   - 엔진: RabbitMQ 3.12+
   - 노드 설정: 단일 노드 또는 클러스터 (향후 HA 확장 가능)
   - 배치: 사설 서브넷 (10.0.21.0/24)
   - EBS: 20GB (메시지 큐 용도)

2. Virtual Host 및 사용자 설정
   - Virtual Host: `/billage` 생성
   - 사용자: `billage_app` 생성 (Backend용)
   - 권한: vhost 내 모든 자원에 대한 configure, write, read 권한
   - Secrets Manager에 비밀번호 저장

3. RabbitMQ 파라미터 설정
   - Prefetch: 32 (채팅 메시지 처리량)
   - Message TTL: 설정 안함 (영구 보관)
   - Dead Letter Exchange: 설정 (메시지 손실 방지)
   - Connection timeout: 60초
   - Heartbeat: 60초

4. Security Group
   - Backend SG: 포트 5672 (AMQP) 접근 허용
   - Frontend SG: 포트 61613 (STOMP WebSocket) 접근 필요한 경우

5. 모니터링 및 백업
   - CloudWatch 알람: Memory 80%, Connection count > 500
   - 설정 파일 백업 (Infrastructure as Code)
   - 스냅샷: 자동 백업 (24시간마다)

**참조 문서:** 04-rabbitmq.md

### 7.5 ECR 리포지토리 생성 (Week 1)

**항목:**
1. ECR 리포지토리
   - billage-be (Backend)
   - billage-fe (Frontend)
   - billage-ai (AI)

2. 라이프사이클 정책
   - 최신 10개 이미지만 유지
   - 태그 없는 이미지는 30일 후 삭제

3. 이미지 스캔 설정
   - 푸시 시 자동 스캔 활성화 (취약점 검사)

4. 암호화
   - KMS 키 사용 (기본값)

**참조 문서:** 05-ecr.md

### 7.6 Secrets Manager 설정 (Week 1)

**항목:**
1. 비밀값 저장
   - RDS 마스터 비밀번호
   - Redis AUTH 토큰
   - 애플리케이션 JWT 시크릿
   - S3 API 키 (선택적)

2. 로테이션 정책 (향후)
   - RDS 비밀번호: 30일마다 자동 로테이션

3. 접근 제어
   - IAM Role별 정책 설정

**참조 문서:** 06-secrets-manager.md

### 7.7 데이터 마이그레이션 준비 (Week 1-2)

**항목:**
1. v1 MySQL 백업
   - mysqldump 실행
   - 압축하여 S3에 저장

2. v2 RDS 복구
   - S3에서 덤프 파일 다운로드
   - mysql 클라이언트로 복원
   - 데이터 검증 (행 수, 체크섬, 샘플 데이터)

3. 스키마 마이그레이션
   - MySQL 5.7 → 8.0 호환성 검사
   - Charset 변경 (utf8 → utf8mb4)
   - 인덱스 재분석

4. 테스트 데이터로 검증
   - 샘플 SELECT 쿼리 실행
   - 애플리케이션 연결 테스트

**참조 문서:** 07-data-migration.md

---

## 8. 전체 타임라인 및 마일스톤

### 8.1 캘린더 기반 계획

**Week 1 (Day 1-7): 기반 구축 (병렬 작업)**
- Day 1-2: VPC, 서브넷, NAT, Endpoint 생성 (DevOps)
- Day 2-3: Security Group, IAM Role 설정 (DevOps)
- Day 3: RDS, RabbitMQ 프로비저닝 시작 (DevOps)
- Day 4: 데이터 마이그레이션 (mysqldump + RDS 복원) (DBA)
- Day 5-6: 데이터 검증, ECR 리포지토리 생성 (DBA + DevOps)
- Day 7: v2 인프라 기본 완성 (DevOps 검수)

**Phase A: 외부 서비스 전환 (Week 1-3, v1에서 수행)**

**Week 1-2 (Day 1-10): Step 1 - DB 전환**
- Day 1-4: RDS 프로비저닝 및 데이터 마이그레이션 완료
- Day 5-7: 애플리케이션 RDS 연결 코드 수정 (JDBC URL 변경)
- Day 8: Runbook 리허설 완료 (실제 전환 절차 검증)
- Day 9: 단일 인스턴스에서 Host MySQL → RDS 전환 실행
- Day 10: 전환 후 모니터링 (응답 시간, 에러율 정상 확인)

**Week 2-3 (Day 11-21): Step 2 - 메시지 브로커 전환**
- Day 11-14: RabbitMQ 프로비저닝 및 Spring 통합 코드 작성
  - Spring Simple Broker → RabbitMQ STOMP Broker 전환
  - WebSocket 엔드포인트 테스트
- Day 15: Runbook 리허설 완료
- Day 16: 단일 인스턴스에서 Simple Broker → RabbitMQ 전환 실행
- Day 17: 채팅 기능 테스트 (메시지 발행/구독 정상 확인)
- Day 18-21: 안정성 모니터링 (WebSocket 동시 연결 수, 메시지 지연)

**Phase B: v2 환경 검증 (Week 3-4, 트래픽 0)**

**Week 3-4 (Day 15-28): 애플리케이션 및 ASG 구축**
- Day 15-18: Docker 이미지 빌드 및 ECR 푸시 (Backend팀 + DevOps)
  - Phase A의 RDS/RabbitMQ 변경사항 포함
  - 모든 환경변수 Secrets Manager에서 주입
- Day 19-20: Launch Template 생성 및 User Data 검증
- Day 21: GitHub Actions OIDC 및 CI/CD 파이프라인 구성
- Day 22: ASG 생성 (Backend, Frontend, AI) 및 부팅
- Day 23-24: 헬스 체크 통과, 통합 테스트 (API, WebSocket, RabbitMQ 연동)
- Day 25-28: 부하 테스트 (100 → 300 → 900 QPS)
  - 에러율, 응답 시간, 데이터베이스 성능 측정
  - Go/No-Go 결정 (4/4 팀 만장일치)

**Phase C: 트래픽 전환 (Week 4-5)**

**Week 4-5 (Day 29-40): Route 53 Weighted Routing**
- Day 29: Route 53 설정 (v1: 100%, v2: 0%)
- Day 30-31: 모니터링 베이스라인 수집 (v1 성능 baseline)
- Day 32: v2 트래픽 5% (v1: 95%, v2: 5%) - 카나리
  - 에러율 < 0.5% 확인
- Day 33-34: 모니터링 + v2 로그 분석
- Day 35: v2 트래픽 30% (v1: 70%, v2: 30%)
  - 에러율 < 0.1% 확인
- Day 36-37: 모니터링
- Day 38: v2 트래픽 80% (v1: 20%, v2: 80%)
  - 최종 검증: 데이터 일관성, 응답 시간 동등
- Day 39-40: v2 안정성 최종 확인

**Phase D: v1 정리 (Week 5-6)**

**Week 5-6 (Day 41-42): 완전 전환 및 정리**
- Day 41: v2 트래픽 100% (v1: 0%, v2: 100%)
- Day 42: v1 인스턴스 백업, 보안 그룹 정리
  - v1 EBS 스냅샷 생성
  - 1주일 후 자동 종료 스케줄 설정 (롤백 버퍼)
- Day 42+: v2 성능 모니터링 (7일간), 회고 진행

### 8.2 마일스톤 및 체크포인트

| 마일스톤 | 날짜 | 체크리스트 |
|---------|------|----------|
| **기반 구축 완료** | Day 7 | VPC, RDS, RabbitMQ 프로비저닝 + 데이터 마이그레이션 완료 |
| **Phase A 완료 (RDS 전환)** | Day 10 | 단일 서버에서 Host MySQL → RDS 전환 + 모니터링 정상 |
| **Phase A 완료 (RabbitMQ 전환)** | Day 21 | 단일 서버에서 Simple Broker → RabbitMQ 전환 + 채팅 테스트 정상 |
| **Phase B 완료 (v2 배포)** | Day 28 | Docker 이미지 빌드 완료, ASG 구축 완료, 부하 테스트 통과 (900 QPS) |
| **Phase C 시작 (카나리)** | Day 32 | Route 53 활성화, v2 5% 트래픽, 에러율 < 0.5% |
| **30% Traffic Shift** | Day 35 | v1: 70%, v2: 30%, 에러율 < 0.1% |
| **80% Traffic Shift** | Day 38 | v1: 20%, v2: 80%, 데이터 일관성 100% |
| **완전 전환** | Day 41 | v2 100%, v1 트래픽 0 (롤백 버퍼 유지) |
| **마이그레이션 완료** | Day 42 | v1 백업 완료, Phase D 정리 시작 |

### 8.3 "Point of No Return" (PNR) 정의

각 Phase마다 되돌릴 수 없는 지점이 존재:

**Phase A PNR (Day 9, Host MySQL → RDS 전환):**
- v1 단일 서버에서 Host MySQL → RDS로 실제 전환 시점
- 이전: Runbook 리허설 가능, 롤백 간단 (RDS 미사용)
- 이후: RDS 활성 데이터베이스로 사용, v1과 v2 모두 RDS 의존
- 롤백: Host MySQL에서 최신 스냅샷 복구 (10분)

**Phase A PNR 2 (Day 16, Simple Broker → RabbitMQ 전환):**
- v1 단일 서버에서 메시지 브로커 전환 시점
- 이전: 기존 Simple Broker 로직 유지 가능
- 이후: RabbitMQ 메시지 채널 활성, 모든 실시간 기능이 RabbitMQ 의존
- 롤백: 애플리케이션 코드를 Simple Broker로 복구 (15분 + 배포)

**Phase C PNR (Day 32, 5% Canary):**
- Route 53 Weighted Routing 활성화 시점 (v2로 첫 트래픽 진입)
- 이전: v2 환경은 모의 테스트만 가능, 실제 트래픽 영향 0
- 이후: v1, v2 동시 모니터링 필수, 실제 사용자 일부가 v2 사용
- 롤백: Route 53 Weight를 v1: 100%, v2: 0% 변경 (1분)

**Phase C PNR 2 (Day 38, 80% Traffic):**
- v2 트래픽이 실제 사용자의 대다수
- 이전: 데이터 검증 추가 시간 가능, 문제 발견 시 v1로 복구 가능
- 이후: v2 트래픽이 압도적 → 데이터 일관성 최종 검증 필수
- 롤백: Route 53 복구 (1분), 하지만 v1이 v2 데이터 변경사항을 따라가지 못할 가능성 높음

**Phase D PNR (Day 41, 100% Traffic Shift):**
- v2 완전 전환, v1 트래픽 0% 선언
- 이전: v1로 즉시 롤백 가능 (Route 53 변경)
- 이후: v1 백업은 유지하지만 활성 서비스가 아님
- 롤백: 가능하지만 v1이 새로운 데이터를 받지 못함 (데이터 손실 위험)
- 대신 RDS 스냅샷에서 복구 (30분)

**Phase D PNR 2 (Day 42+, v1 인스턴스 정리):**
- v1 EBS 스냅샷 생성 후, 1주일 후 자동 종료 스케줄 설정
- 이전: v1 복구 가능 (EBS 데이터 물리적 존재)
- 이후: 인스턴스 삭제 (설정 파일 등 물리적 접근 불가)
- 하지만 RDS 스냅샷이 있으므로 데이터 복구는 여전히 가능

---

## 9. 리스크 매트릭스 및 대응 전략

### 9.1 리스크 식별 및 평가

| # | 리스크 | 확률 | 영향도 | 심각도 | 대응 전략 | 담당 |
|---|--------|------|--------|--------|----------|------|
| 1 | RDS 프로비저닝 지연 | 중 | 높음 | **높음** | AWS Support 연락, 사전 quota 증가 | DevOps |
| 2 | 데이터 마이그레이션 실패 | 낮음 | 매우높음 | **매우높음** | 덤프 검증 3회, 샘플 쿼리 테스트 | DevOps + DBA |
| 3 | RabbitMQ 프로비저닝/연동 실패 | 중 | 높음 | **높음** | 로컬에서 Spring STOMP 통합 테스트 사전 완료 | Backend + DevOps |
| 4 | Docker 이미지 빌드 실패 | 중 | 중간 | 중간 | 로컬에서 먼저 빌드 테스트, CI/CD 테스트 | Backend팀 |
| 5 | Route 53 DNS 캐시 이슈 | 낮음 | 중간 | 중간 | TTL 300초로 사전 설정, 점진적 가중치 변경 | DevOps |
| 6 | v2에서 예상 못한 에러 (Phase C 중) | 중 | 높음 | **높음** | 카나리 테스트(5%)에서 검출, 즉시 v1로 복구 (1분) | 전체 |
| 7 | WebSocket/RabbitMQ 메시지 손실 | 중 | 높음 | **높음** | RabbitMQ 메시지 영속성 설정, 재연결 로직 구현 | Backend + DevOps |
| 8 | RDS 성능 부족 (CPU > 90%) | 중 | 높음 | **높음** | db.t4g.small로 즉시 업그레이드, 쿼리 최적화 | DevOps + Backend |
| 9 | RabbitMQ 메모리/연결 부족 | 낮음 | 중간 | 중간 | 모니터링으로 사전 감지, 인스턴스 업그레이드 | DevOps |
| 10 | 배포 중 Connection Reset (세션/메시지 손실) | 중 | 중간 | 중간 | Connection Draining (300초), RabbitMQ 재연결 로직 | Frontend + Backend팀 |
| 11 | ALB 타겟 그룹 헬스 체크 실패 | 중 | 높음 | **높음** | Health check path 정의 (/actuator/health), threshold 3회 연속 실패 | DevOps + Backend |
| 12 | Security Group 규칙 누락 (RabbitMQ) | 낮음 | 높음 | **중간** | 체크리스트 검증 (telnet, 포트 5672 연결 테스트), 통합 테스트 | DevOps |
| 13 | IAM Role 권한 부족 | 낮음 | 중간 | 중간 | CloudTrail 로그 확인, 사후 권한 추가 | DevOps + Security |
| 14 | v1에서 신규 데이터 발생 (Phase C 중) | 낮음 | 매우높음 | **매우높음** | 데이터 마이그레이션 도구 (CDC, 이벤트 리플리케이션) 미리 구성 | Backend + DevOps |
| 15 | GitHub Actions 시크릿 노출 | 매우낮음 | 매우높음 | **높음** | GitHub 리포지토리 보안 설정, 정기 검토 | Security |
| 16 | 비용 초과 (Dual-run) | 중 | 낮음 | 낮음 | 예산 알람 설정 (매일 체크), 사전 비용 분석 | Finance |

### 9.2 우선순위별 대응

**Priority 1: Phase A 전환 (RDS + RabbitMQ) 실패 (Risk #2, #3, #7, #14)**

*사전 조치:*
- v1 MySQL에서 정기적(6시간마다) 백업 이미 진행 중
- v2 RDS 복구 전: mysqldump로 3회 검증
  1. 덤프 행 수 확인 (`SELECT COUNT(*)`)
  2. 체크섬 계산 (모든 테이블)
  3. 샘플 쿼리 10개 수행 (복잡한 JOIN 포함)
- RabbitMQ 연동 테스트: Spring STOMP 클라이언트 로컬 환경에서 메시지 발행/구독 확인
  - WebSocket 동시 연결 테스트 (최소 100 연결)
  - 메시지 영속성 설정 확인 (durable queues)

*Phase A 중 발생 시 절차:*
- RDS 전환 실패: Host MySQL로 즉시 복구 (10분)
- RabbitMQ 전환 실패: Spring Simple Broker로 즉시 복구 (15분)
- Phase C (Strangler) 시작 전에는 v1만 활성이므로, 실제 사용자 영향 최소화

**Priority 2: RDS + RabbitMQ 성능 부족 (Risk #7, #8, #9)**

*모니터링:*
- RDS: CloudWatch 알람: CPU > 80% (5분 평균), 응답 시간 P95 > 250ms → 경고
- RabbitMQ: 메모리 > 80%, 연결 수 > 500 → 경고

*확장 전략:*
- RDS: db.t4g.small로 즉시 업그레이드 (1시간)
- RabbitMQ: Amazon MQ 인스턴스 업그레이드 또는 클러스터 전환 (2시간)
- 병렬: 느린 쿼리 분석 및 인덱스 추가, RabbitMQ prefetch 조정

**Priority 3: v2 예상 못한 에러 (Risk #6, #10)**

*Phase C 단계별 에러 처리 기준:*
- 5% 카나리 (Day 32): 에러율 상한 0.5% → 초과 시 즉시 0%로 복구
- 30% (Day 35): 에러율 상한 0.1%
- 80% (Day 38): 에러율 상한 0.05% (매우 엄격)
- 100% (Day 41): 에러율 상한 0.01% 유지 확인

*롤백 절차 (5분 이내):*
1. Route 53 Weight를 이전 상태로 변경 (DNS TTL 300초)
2. CloudWatch Logs에서 에러 추적 (특히 WebSocket/RabbitMQ 관련)
3. v2 로그 분석 + 팀별 상황 회의 (최대 10분)
4. 버그 분류:
   - Application 버그: 수정 후 새 Docker 이미지 푸시 → 재시도
   - Infrastructure 버그: Security Group/RabbitMQ 설정 수정 → 재시도
   - 알 수 없음: 즉시 v1로 100% 복구 → 심화 분석

**Priority 4: 보안 그룹/IAM 설정 누락 (Risk #12, #13)**

*사전 체크리스트:*
```
Network Connectivity:
☐ Backend → RDS (3306) 통신 가능 (telnet/mysql 테스트)
☐ Backend → RabbitMQ (5672) 통신 가능 (telnet 테스트)
☐ ALB → Backend (8080) 통신 가능 (health check 통과)
☐ NAT Gateway → ECR, S3 (443) 통신 가능
☐ RabbitMQ Management UI → Backend (15672) 접근 불필요 (내부용)

IAM Verification:
☐ Backend IAM Role이 ECR, S3, RDS, RabbitMQ, Secrets Manager read 권한 있음
☐ GitHub Actions OIDC가 ECR push, Launch Template update 권한 있음
☐ CloudWatch Logs에 애플리케이션 로그 기록됨
☐ Secrets Manager에 RabbitMQ 사용자명/비밀번호 저장됨

RabbitMQ Configuration:
☐ Virtual Host `/billage` 생성
☐ 사용자 생성 (Backend용) + 권한 설정
☐ Message persistence 활성화 (durable queues)
☐ Prefetch 설정 (권장: 32)
```

---

## 10. 의사소통 계획

### 10.1 점검 공지 및 주기

**주간 스탠드업 (매주 월요일 10:00 KST)**
- 전날 완료 항목 (60초)
- 당일 계획 (60초)
- 블로킹 이슈 (120초)
- 참석: DevOps, Backend, Frontend, AI팀 리드

**마일스톤 검토 회의 (7일마다)**
- Day 7, 14, 21, 28, 35, 42, 49, 56
- 정시: 오후 2:00 KST, 60분
- 안건:
  1. 체크리스트 진행률
  2. 리스크 상태 변경
  3. 다음 Phase 승인 여부
- 결정: Go/No-go 투표 (4-0 만장일치)

**Strangler Fig 일일 모니터링 (Phase 2부터)**
- 매일 8:00 AM 그래프 검토 (5분)
  - 에러율, 응답 시간, RDS CPU
- 이상 감지 시 즉시 회의 소집

**Post-Migration Retrospective (Day 60)**
- 90분 회의
- 배운 점, 개선사항 정리
- 다음 마이그레이션 체크리스트 수정

### 10.2 알림 체계 및 에스컬레이션

**CloudWatch 알람 → Slack/Discord 자동 전송**

```
Severity Levels:
- CRITICAL (빨강): 즉시 대응 필요
  ├─ RDS CPU > 90%
  ├─ ALB HTTP 5xx > 5%
  ├─ ASG 인스턴스 Unhealthy > 1
  └─ 담당: DevOps (on-call)

- WARNING (주황): 1시간 내 대응
  ├─ RDS CPU > 80%
  ├─ 응답 시간 P95 > 500ms
  └─ 담당: Backend팀

- INFO (파랑): 정보성 알림
  ├─ ASG 스케일링 이벤트
  ├─ 배포 완료
  └─ 담당: 팀 공유
```

**에스컬레이션 경로 (Critical):**

1. **Level 1** (0-15분): DevOps on-call 자동 페이징
2. **Level 2** (15분 미응답): DevOps 팀리드에게 Phone call
3. **Level 3** (30분 미해결): 기술 리드 + 경영진 공지
4. **Level 4** (1시간 미해결): CEO, 고객 서포트팀 보고

### 10.3 롤백 판단 기준

**자동 롤백 (무조건 실행):**
- ALB HTTP 5xx 비율 > 10% (1분 평균)
- RDS 연결 불가능 (3회 이상 실패)
- ASG 인스턴스 모두 Unhealthy 상태

**수동 롤백 (팀 검토 후 결정):**
- 에러율 > 1% (1시간 지속)
- 응답 시간 P95 > 500ms (1시간 지속)
- 데이터 불일치 감지 (중요 테이블)

**롤백 절차 (5분 이내):**
1. Route 53 Weight 조정 (v2: current% → 0%)
2. Slack에 "ROLLBACK INITIATED" 공지
3. 1분 대기 (DNS TTL), CloudWatch 확인
4. 에러율 정상 확인 시 롤백 완료

---

## 11. 성공 기준 및 완료 판정

마이그레이션이 "성공"했다고 판정하기 위한 정량적 기준:

### 11.1 기술적 성공 기준

| 항목 | 기준 | 측정 방법 |
|------|------|----------|
| **서비스 가용성** | 99.95% | CloudWatch 계산 (5분 윈도우) |
| **응답 시간 (P95)** | < 200ms | APM/ALB 로그 분석 |
| **에러율** | < 0.1% | CloudWatch Logs 에러 계산 |
| **데이터 일관성** | 100% | v1 vs v2 쿼리 비교 (샘플 100건) |
| **배포 시간** | < 3분 | GitHub Actions 실행 시간 |
| **배포 다운타임** | 0초 | ALB 헬스 체크, connection draining |
| **RDS 성능** | CPU < 60%, 커넥션 < 70 | CloudWatch 메트릭 |
| **Redis 성능** | 메모리 < 60%, 히트율 > 70% | ElastiCache 메트릭 |
| **자동 스케일링** | CPU > 70% 시 인스턴스 추가 | ASG 이벤트 로그 |
| **보안 규칙 준수** | IAM least privilege | IAM Policy Simulator |

### 11.2 운영 성공 기준

| 항목 | 기준 | 측정 방법 |
|------|------|----------|
| **배포 신뢰도** | 실패율 < 2% | 지난 10회 배포 통계 |
| **모니터링 커버리지** | 주요 메트릭 > 50개 | CloudWatch 대시보드 |
| **알림 정확도** | 오탐율 < 10% | Slack 알림 로그 검토 |
| **MTTR** (평균 복구 시간) | < 15분 | 인시던트 기록 |
| **MTTD** (평균 탐지 시간) | < 2분 | 알림 트리거 시간 |
| **도서화 완성도** | 100% | 문서 체크리스트 |
| **팀 교육** | 모든 팀원이 운영 매뉴얼 읽음 | 체크 항목 기록 |

### 11.3 비즈니스 성공 기준

| 항목 | 기준 |
|------|------|
| **비용 절감** | 월 비용 ± 10% (초기 Dual-run 비용 제외) |
| **스케일링 능력** | 트래픽 3배 증가 시 자동 스케일 (수동 개입 0) |
| **배포 안정성** | 중단 없는 배포 (무중단 배포 달성) |
| **팀 만족도** | DevOps 팀 설문 점수 > 4/5 |
| **SLA 달성** | Uptime 99.95% 달성 (7일 이상) |

### 11.4 최종 판정 체크리스트

마이그레이션 완료 선언 전 확인 항목:

```
기술:
☐ 모든 서비스 v2에서 실행 중 (v1 트래픽 0%)
☐ 에러율 < 0.1% (지난 7일 평균)
☐ 응답 시간 P95 < 200ms (지난 7일 평균)
☐ RDS 자동 스케일 테스트 성공 (CPU 급증 시뮬레이션)
☐ ASG 자동 스케일 테스트 성공 (트래픽 3배)
☐ 배포 3회 이상 무중단 완료
☐ 롤백 테스트 성공 (RDS 스냅샷 복구)

운영:
☐ 24시간 모니터링 완료 (문제 0건)
☐ 팀 전원이 v2 운영 매뉴얼 숙독
☐ On-call 절차 정의 및 훈련
☐ 재해 복구 계획 수립

비즈니스:
☐ 고객 영향 0건 (마이그레이션 기간 중)
☐ 예약/결제 시스템 정상 작동
☐ 마이그레이션 후기 작성 완료

최종 승인:
☐ DevOps 팀리드 사인오프
☐ Backend 팀리드 사인오프
☐ 기술 리드 최종 검토
```

---

## 12. 관련 문서 참조

이 마스터 문서는 다음 세부 문서들과 함께 사용됩니다:

| 문서명 | 담당자 | 설명 |
|--------|--------|------|
| **01-networking.md** | DevOps | VPC 설계, 서브넷, NAT, Endpoint 상세 설정 |
| **02-iam-oidc.md** | DevOps + Security | IAM Role, 정책, GitHub Actions OIDC 구성 |
| **03-rds-mysql.md** | DBA + DevOps | RDS 생성, 파라미터 그룹, 백업, 모니터링 |
| **04-rabbitmq.md** | Backend + DevOps | RabbitMQ 프로비저닝, Spring STOMP 통합, 메시지 설정 |
| **05-ecr.md** | DevOps | ECR 리포지토리, 라이프사이클, Docker 이미지 가이드 |
| **06-secrets-manager.md** | DevOps + Security | 비밀값 저장, 로테이션, 접근 제어 (DB, RabbitMQ, JWT 포함) |
| **07-data-migration.md** | DBA + Backend | MySQL 덤프, RDS 복구, 검증 프로세스 |
| **08-phase-a-migration.md** | Backend + DevOps | Phase A 상세 (RDS 전환, RabbitMQ 전환, 리허설 runbook) |
| **09-launch-templates.md** | DevOps + Backend | Launch Template 작성, User Data, 스크립트 |
| **10-asg-setup.md** | DevOps | ASG 생성, 스케일링 정책, 헬스 체크 |
| **11-alb-routing.md** | DevOps | ALB 라우팅 규칙, 타겟 그룹, SSL |
| **12-github-actions.md** | Backend + DevOps | CI/CD 파이프라인, Docker build, ECR push |
| **13-phase-c-strangler.md** | DevOps | Phase C 상세 (Route 53 가중치 라우팅, 트래픽 전환, 모니터링) |
| **14-monitoring-dashboards.md** | DevOps | CloudWatch, Grafana 대시보드, 알람 (RabbitMQ 포함) |
| **15-runbook-operations.md** | DevOps | 운영 매뉴얼, 공통 문제 해결 (RabbitMQ 장애 대응) |
| **16-cost-analysis.md** | Finance + DevOps | 비용 분석, 예산, 절감 기회 |

---

## 마치며

이 마이그레이션은 Billage의 **수직 확장 한계를 뛰어넘고 수평 확장의 길을 여는** 전략적 전환입니다.

**핵심 원칙:**
1. **위험 최소화:** Strangler Fig로 점진적 전환, 언제든 v1로 복구 가능
2. **검증 우선:** 각 단계마다 데이터/성능 검증, PNR 명확히
3. **자동화 강화:** CI/CD, ASG, 알림으로 수동 개입 최소화
4. **운영 준비:** 도서화, 교육, 모니터링으로 v2 운영 체계 정비

**예상 기대 효과:**
- RTO: 10분 → < 1분 (99.9% 개선)
- 배포 시간: 10분 → 3분 (70% 단축)
- 무중단 배포 달성 (비즈니스 임팩트 0)
- 트래픽 3배 자동 스케일 가능

**책임:**
- 마이그레이션 리더십: DevOps 팀
- 기술 검증: Backend, Frontend, AI팀
- 최종 승인: CTO/기술 리드

**시작 일자:** Day 1 (합의 후 48시간)
**예상 완료:** Day 57 (9주)
**최종 검증:** Day 63 (9주 + 6일)

---

**문서 버전:** v1.0
**작성일:** 2025년 2월
**최종 검토:** -
**승인자:** -

