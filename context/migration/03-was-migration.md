# WAS 마이그레이션 계획 (Web Application Server Migration)

## 1. 개요

Billage 플랫폼은 현재 단일 EC2 인스턴스에서 Spring Boot, Next.js, FastAPI를 systemd로 관리하는 모놀리식 배포 구조에서 **마이크로서비스 기반 컨테이너 아키텍처로 전환**한다. 이는 단순한 컨테이너화를 넘어 **배포 전략, 프로세스 관리, 환경 주입, 모니터링 파이프라인을 완전히 재설계**하는 복잡한 마이그레이션이다.

### 1.1 마이그레이션의 핵심 가치

- **확장성**: 각 서비스가 독립적인 ASG(Auto Scaling Group)로 분리되어 서비스별 스케일링 정책 적용 가능
- **배포 자동화**: SCP/SSH 기반 배포에서 ECR/Instance Refresh로 전환 → 무중단 배포 (Instance Replacement)
- **리소스 효율**: 서비스별 용량 계획 가능 (BE: t4g.small, FE: t4g.small, AI: t4g.small)
- **운영 개선**: Docker stdout/stderr를 Promtail로 수집 → 파일 기반 로깅 제거

### 1.2 마이그레이션 난제 요약

| 항목 | v1 (현재) | v2 (목표) | 도전 과제 |
|------|---------|---------|---------|
| **프로세스 관리** | systemd (파일 기반) | Docker (컨테이너) | 재시작 정책, graceful shutdown 처리 |
| **배포 방식** | SCP JAR + SSH restart | ECR + Instance Refresh | 파이프라인 전체 재설계, 이미지 빌드 최적화 |
| **리버스 프록시** | Nginx (port 80) | ALB (Layer 7 routing) | Nginx 제거, ALB health check 구성 |
| **환경 주입** | systemd EnvironmentFile | SSM Parameter Store + user_data | 런타임 의존성 동적 조회 |
| **로깅** | /var/log/billage/{service}/ | Docker stdout → Promtail | 로그 드라이버 선택, 라벨링 전략 |
| **모니터링** | Node Exporter (기존) | Node Exporter + cAdvisor + Promtail | 컨테이너 레벨 메트릭 수집 추가 |
| **리소스 한계** | 단일 t4g.medium (4GB, 2 vCPU) | BE: 2-6 × t4g.small (각 2GB, 1vCPU)<br/>FE: 2-3 × t4g.small<br/>AI: 1-2 × t4g.small | 메모리 제약 심각 (JVM 1GB max, Docker 200MB 공유) |

---

## 2. 현재 상태 (AS-IS: v1)

### 2.1 인프라 구성

```
EC2: t4g.medium (4GB RAM, 2 vCPU, Ubuntu 22.04)
├── Spring Boot (port 8080)
│   ├── Service: billage-backend
│   ├── JAR: /opt/billage/backend/target/billage-backend-*.jar
│   ├── JVM opts: -Xmx2g -Xms2g (systemd service file에 정의)
│   └── DB: localhost:3306 (application.yml에 하드코딩)
├── Next.js (port 3000)
│   ├── Service: billage-frontend
│   ├── PM2: ecosystem.config.js (standalone mode)
│   ├── Directory: /opt/billage/frontend/.next
│   └── NEXT_PUBLIC_API_URL: https://dev.billages.com/api
├── FastAPI (port 5000)
│   ├── Service: billage-ai
│   ├── Uvicorn: 0.0.0.0:5000 (systemd에서 ExecStart)
│   ├── Python deps: /opt/billage/ai/venv/lib/python3.10/site-packages
│   └── RunPod API Key: 환경변수 (systemd EnvironmentFile에 저장)
└── Nginx (port 80)
    ├── /        → localhost:3000 (Next.js)
    ├── /api/    → localhost:8080 (Spring Boot)
    └── /ai/     → localhost:5000 (FastAPI)
```

### 2.2 배포 흐름 (CI/CD v1)

```
GitHub Push
    ↓
GitHub Actions Workflow
    ├── [BE 변경] paths-filter:
    │   ├── build-backend.yml
    │   ├── Maven build → JAR 생성
    │   ├── SCP → /opt/billage/backend/target/
    │   ├── SSH → systemctl restart billage-backend
    │   └── systemd restart (JVM cold start 지연)
    │
    ├── [FE 변경] paths-filter:
    │   ├── build-frontend.yml
    │   ├── npm run build → .next 디렉토리
    │   ├── rsync → /opt/billage/frontend/.next
    │   ├── SSH → systemctl restart billage-frontend
    │   └── PM2 graceful restart (SIGTERM → 타임아웃 위험)
    │
    └── [AI 변경] paths-filter:
        ├── build-ai.yml
        ├── 의존성 업데이트 & 파일 복사
        ├── rsync → /opt/billage/ai/
        ├── SSH → systemctl restart billage-ai
        └── uvicorn restart

S3 접근: IAM Instance Profile
    ├── IMDS (Instance Metadata Service) v2: hop_limit=2
    ├── EC2 내부 프로세스가 presigned URL 생성
    └── presigned URL을 Frontend에 응답
```

### 2.3 현재 아키텍처의 문제점

- **확장성 부재**: 모든 서비스가 동일한 인스턴스에서 실행 → CPU 급증 시 전체 scale-out (비효율)
- **배포 복잡성**: 3개 서비스별로 다른 빌드/배포 스크립트 관리
- **무중단 배포 미흡**: systemd restart → 기존 연결 즉시 종료 (graceful shutdown 불완전)
- **리소스 활용 저하**: t4g.medium (4GB) 중 일부만 사용, 나머지 낭비
- **모니터링 한계**: 파일 기반 로깅, 컨테이너 메트릭 부재 (나중에 Docker 전환 시 기술부채)

---

## 3. 목표 상태 (TO-BE: v2)

### 3.1 인프라 구성

```
Application Load Balancer (ALB)
├── Listener: port 80 (HTTP)
│   └── Target Group routing
│       ├── /api/*      → Backend Target Group (port 8080)
│       ├── /          → Frontend Target Group (port 3000)
│       └── /ai/*      → AI Target Group (port 5000)
│
├── Backend Auto Scaling Group (300K MAU: 900 RPS 처리)
│   ├── Launch Template: lt-billage-backend-v*
│   ├── Instance type: t4g.small (2GB RAM, 1 vCPU)
│   ├── Desired: 3, Min: 2, Max: 6 (각 인스턴스 ~150 RPS)
│   ├── Health check: /actuator/health (HTTP, interval 30s, grace 240s)
│   ├── Scale-out: CPU > 70%, Target: 50%
│   ├── Termination policy: Balanced (graceful drain 60s)
│   └── user_data: user_data_backend.sh.tpl
│       ├── ECR login (IAM Instance Profile)
│       ├── SSM Parameter 동적 조회 (/billage/dev/backend/*)
│       ├── Docker pull 753159922519.dkr.ecr.ap-northeast-2.amazonaws.com/billage-be:latest
│       └── Docker run -e 환경변수 + JVM튜닝 (-Xms800m -Xmx1000m)
│
├── Frontend Auto Scaling Group (300K MAU: 3,000-5,000 concurrent)
│   ├── Launch Template: lt-billage-frontend-v*
│   ├── Instance type: t4g.small (2GB RAM, 1 vCPU)
│   ├── Desired: 2, Min: 2, Max: 3 (각 인스턴스 1,500-2,500 concurrent)
│   ├── Health check: / (HTTP, interval 30s, grace 120s)
│   ├── Scale-out: CPU > 75%
│   └── user_data: user_data_frontend.sh.tpl
│       ├── ECR login
│       ├── Docker pull 753159922519.dkr.ecr.ap-northeast-2.amazonaws.com/billage-fe:latest
│       └── Docker run (NEXT_PUBLIC_API_URL 빌드 타임 주입 완료)
│
└── AI Auto Scaling Group (추천: 비동기, RunPod 위임)
    ├── Launch Template: lt-billage-ai-v*
    ├── Instance type: t4g.small (2GB RAM, 1 vCPU)
    ├── Desired: 1, Min: 1, Max: 2 (병목 아님, 스케일링 불필요)
    ├── Health check: /health (HTTP, interval 30s, grace 120s)
    └── user_data: user_data_ai.sh.tpl
        ├── ECR login
        ├── SSM Parameter 동적 조회
        └── Docker pull & run (RunPod API Key 주입)

ECR Repositories
├── billage-be (tag policy: immutable, keep_10_images)
│   └── 753159922519.dkr.ecr.ap-northeast-2.amazonaws.com/billage-be:{semver}-{git-sha}
├── billage-fe
│   └── 753159922519.dkr.ecr.ap-northeast-2.amazonaws.com/billage-fe:{semver}-{git-sha}
└── billage-ai
    └── 753159922519.dkr.ecr.ap-northeast-2.amazonaws.com/billage-ai:{semver}-{git-sha}

Security Groups
├── sg-billage-alb: 0.0.0.0/0:80 (inbound)
├── sg-billage-backend: sg-billage-alb:8080 (inbound)
├── sg-billage-frontend: sg-billage-alb:3000 (inbound)
├── sg-billage-ai: sg-billage-alb:5000 (inbound)
└── 모든 ASG: 자신의 SG만 허용 (서로 통신 불필요)

S3 접근: IAM Instance Profile 유지
├── EC2 → IMDS (hop_limit=2)
├── Docker 컨테이너 → host의 IMDS 접근 (--net host or 169.254.169.254)
└── presigned URL 생성 로직 변경 없음
```

### 3.2 배포 흐름 (CI/CD v2)

```
GitHub Push
    ↓
GitHub Actions Workflow
    ├── [BE 변경] detect-changes:
    │   ├── Setup: OIDC → AWS credentials
    │   ├── Docker build:
    │   │   ├── Dockerfile (multi-stage, ARM64)
    │   │   ├── Cache: ghcr.io/billage/billage-be:buildcache
    │   │   └── Result: 753159922519.dkr.ecr.ap-northeast-2.amazonaws.com/billage-be:1.0.0-abc1234
    │   ├── ECR scan on push (vulnerability detection)
    │   ├── Update Launch Template:
    │   │   └── user_data 업데이트: latest 태그로 이미지 참조
    │   ├── ASG Instance Refresh 시작:
    │   │   ├── MinHealthyPercentage: 90%
    │   │   ├── 기존 인스턴스 1개 → 새 인스턴스 시작
    │   │   ├── 새 인스턴스 health check (240s grace period)
    │   │   ├── 통과 → ALB Target Group에 등록
    │   │   └── 기존 인스턴스 termination (graceful drain 60s)
    │   └── [결과] 무중단 배포 완료
    │
    ├── [FE 변경] detect-changes:
    │   ├── Docker build:
    │   │   ├── Dockerfile (multi-stage, standalone mode)
    │   │   ├── NEXT_PUBLIC_API_URL 빌드 타임 주입
    │   │   └── Result: billage-fe:1.0.0-def5678
    │   ├── ECR push
    │   ├── Instance Refresh (MinHealthyPercentage: 100%, grace: 120s)
    │   └── 무중단 배포
    │
    └── [AI 변경] detect-changes:
        ├── Docker build → billage-ai:1.0.0-ghi9012
        ├── ECR push
        ├── Instance Refresh
        └── 무중단 배포

롤백: Launch Template 버전 N-1로 지정 → Instance Refresh 다시 시작
```

---

## 4. 서비스별 마이그레이션 상세

### 4.1 Backend (Spring Boot) 마이그레이션

#### 4.1.1 Docker 이미지 설계

**Dockerfile 다단계 빌드 (multi-stage)**

```
# Stage 1: Build
FROM public.ecr.aws/amazoncorretto/amazoncorretto:21-al2-jdk as builder
WORKDIR /app
COPY . .
RUN ./mvnw clean package -DskipTests

# Stage 2: Runtime (JRE only)
FROM public.ecr.aws/amazoncorretto/amazoncorretto:21-al2-jre
WORKDIR /app
COPY --from=builder /app/target/billage-backend-*.jar app.jar
EXPOSE 8080
ENTRYPOINT ["java", "-jar", "app.jar"]
```

**이미지 크기 목표**: < 300MB (JRE 기반, JDK 제거)

**ARM64 호환성**
- amazoncorretto 공식 이미지는 ARM64 자동 지원
- Maven 플러그인: maven-compiler-plugin (Java 21 cross-compile 가능)

#### 4.1.2 JVM 메모리 설정

**리소스 제약 분석 (300K MAU, t4g.small 2GB)**

```
t4g.small: 2048MB RAM
├── OS (Linux kernel): ~300MB
├── Docker daemon: ~100MB
├── Node Exporter: ~20MB
├── cAdvisor: ~50MB
├── Promtail: ~30MB
├── 애플리케이션 컨테이너 할당 가능: ~1.5GB

Spring Boot JVM 권장 (900 RPS 처리):
├── -Xmx1000m (max heap, 1GB)
├── -Xms800m (initial heap)
├── metaspace: 256m
├── offheap (NIO buffers, etc): ~50-100MB
└── Total JVM footprint: ~1.2GB (안전)

주의: Xmx=1200m으로 설정 금지!
- 메모리 부족 → OOM killer 활성화
- 컨테이너 강제 종료 → ALB health check 실패
- 인스턴스 교체 → 배포 지연
```

**Dockerfile ENTRYPOINT 설정**

```
ENTRYPOINT ["java", "-Xms800m", "-Xmx1000m", "-XX:+UseG1GC", "-jar", "app.jar"]
```

**권장: user_data에서 JAVA_OPTS 환경변수 주입**

```bash
# user_data_backend.sh.tpl (300K MAU 튜닝)
docker run -d \
  -e JAVA_OPTS="-Xms800m -Xmx1000m -XX:+UseG1GC -XX:MaxGCPauseMillis=200" \
  -m 1.5g \
  --restart unless-stopped \
  ...
```

**참고**:
- `-Xmx1000m`: 900 RPS 기준 안전한 최대 heap
- `-XX:MaxGCPauseMillis=200`: GC pause 최소화 (응답성 향상)
- `-m 1.5g`: Docker 컨테이너 메모리 제한 (안전장치)

#### 4.1.3 환경 변수 관리

**SSM Parameter Store 경로 규칙**

```
/billage/dev/backend/db_host
/billage/dev/backend/db_port
/billage/dev/backend/db_username
/billage/dev/backend/db_password
/billage/dev/backend/jwt_secret
/billage/dev/backend/redis_endpoint
/billage/dev/backend/s3_bucket_name
```

**user_data_backend.sh.tpl에서 동적 조회**

```bash
#!/bin/bash
set -e

# IAM Instance Profile을 통해 SSM 접근
DB_PASSWORD=$(aws ssm get-parameter \
  --name /billage/dev/backend/db_password \
  --with-decryption \
  --query 'Parameter.Value' \
  --output text \
  --region ap-northeast-2)

JWT_SECRET=$(aws ssm get-parameter \
  --name /billage/dev/backend/jwt_secret \
  --with-decryption \
  --query 'Parameter.Value' \
  --output text)

REDIS_ENDPOINT=$(aws ssm get-parameter \
  --name /billage/dev/backend/redis_endpoint \
  --query 'Parameter.Value' \
  --output text)

# ECR 로그인
aws ecr get-login-password --region ap-northeast-2 | \
  docker login --username AWS --password-stdin 753159922519.dkr.ecr.ap-northeast-2.amazonaws.com

# Docker 실행
docker run -d \
  --name billage-backend \
  -p 8080:8080 \
  -e SPRING_DATASOURCE_PASSWORD="$DB_PASSWORD" \
  -e SPRING_DATASOURCE_URL="jdbc:mysql://rds-endpoint:3306/billage?useSSL=true" \
  -e JWT_SECRET="$JWT_SECRET" \
  -e SPRING_REDIS_HOST="$REDIS_ENDPOINT" \
  -e SPRING_REDIS_PORT="6379" \
  -e AWS_REGION="ap-northeast-2" \
  --restart unless-stopped \
  --log-driver json-file \
  --log-opt max-size=10m \
  --log-opt max-file=3 \
  753159922519.dkr.ecr.ap-northeast-2.amazonaws.com/billage-be:latest

# Health check (ALB가 담당하지만 user_data 로그 검증용)
sleep 30
curl -f http://localhost:8080/actuator/health || exit 1
```

#### 4.1.4 DB 연결 변경

**v1**: localhost:3306 (application.yml에 하드코딩)

**v2**: RDS Endpoint + SSM 동적 조회 (300K MAU, 900 RPS)
- RDS Security Group: EC2 ASG security group에서 3306 허용
- 연결 풀 설정 (HikariCP, 인스턴스당):
  - `spring.datasource.hikari.maximum-pool-size=30`
    - 각 인스턴스: ~150 RPS = 30 DB 연결 필요
    - 6 instances × 30 = 180 총 연결 (RDS 안전)
  - `spring.datasource.hikari.minimum-idle=5`
  - `spring.datasource.hikari.connection-timeout=10000`
  - `spring.datasource.hikari.max-lifetime=600000`

#### 4.1.5 ElastiCache Redis (선택사항, 향후 캐시 레이어용)

**현재**: 없음
**v2**: ElastiCache Redis (나중에 캐시 레이어로 추가 가능, JWT 기반 stateless 인증이므로 세션 저장소 불필요)

**참고**:
- Spring Session Redis는 필요 없음 (JWT 토큰 기반 stateless 인증 사용)
- Redis는 향후 채팅 메시지 일시 저장소 또는 일반 캐싱용으로만 사용 (Phase 2에서 상세)
- 현재 Phase 1 (WAS 마이그레이션)에서는 Redis 도입 불필요

#### 4.1.6 Health Check 전략

**ALB Target Group 설정**

```
Protocol: HTTP
Path: /actuator/health
Port: 8080
Interval: 30 seconds
Timeout: 5 seconds
Healthy threshold: 2
Unhealthy threshold: 3
Grace period: 240 seconds (JVM warm-up 고려)
Matcher: 200
```

**Grace Period 240초인 이유 (300K MAU 부하 고려)**
- JVM 기동: ~10초
- Spring Boot 초기화: ~30초 (Redis, DB 연결 포함)
- DB 연결 풀 구성: ~10초 (30 connections 초기화)
- Redis 연결 검증: ~5초
- 첫 health check: ~10초
- GC tuning & 워밍업: ~50초
- 여유: 115초
- **합계: 최악의 경우 240초 필요 (900 RPS 처리 가능 확인)**

#### 4.1.7 Graceful Shutdown

**Spring Boot (기본 지원)**

```
server.shutdown=graceful
spring.lifecycle.timeout-per-shutdown-phase=60s
```

**ASG Termination Policy**

```
Default termination policy: Balanced
Connection draining: 60 seconds
```

**Docker --restart unless-stopped**
- Manual stop 시에만 재시작 안 함
- Crash 시 자동 재시작
- ASG termination 신호 수신 → graceful shutdown 처리

### 4.2 Frontend (Next.js) 마이그레이션

#### 4.2.1 Docker 이미지 설계

**Dockerfile 다단계 빌드**

```
# Stage 1: Build
FROM node:20-alpine as builder
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci
COPY . .
ARG NEXT_PUBLIC_API_URL=https://api.dev.billages.com
ENV NEXT_PUBLIC_API_URL=$NEXT_PUBLIC_API_URL
RUN npm run build

# Stage 2: Runtime (standalone mode)
FROM node:20-alpine
WORKDIR /app
COPY --from=builder /app/.next/standalone ./
COPY --from=builder /app/.next/static ./.next/static
COPY --from=builder /app/public ./public
EXPOSE 3000
CMD ["node", "server.js"]
```

**이미지 크기 목표**: < 200MB (node_modules 제거, .next만 포함)

**Standalone Mode 주의**
- next.config.js:
  ```
  output: 'standalone'
  ```
- 이로 인해 .next/standalone/node_modules만 포함 (의존성 최소화)

#### 4.2.2 NEXT_PUBLIC_API_URL 빌드 타임 주입

**문제**: NEXT_PUBLIC_* 환경변수는 빌드 타임에 결정되어 런타임 변경 불가

**해결책**: 빌드 시점에 결정

```bash
# GitHub Actions (build-frontend.yml)
- name: Build Docker image
  run: |
    docker build \
      --build-arg NEXT_PUBLIC_API_URL=https://dev.billages.com \
      -t billage-fe:${{ github.sha }} .
```

**또는 user_data에서 Dockerfile 생성 후 빌드**

```bash
# user_data_frontend.sh.tpl (비권장, 빌드 시간 증가)
cat > /tmp/Dockerfile.frontend << 'EOF'
...
ARG NEXT_PUBLIC_API_URL=${API_URL}
...
EOF

docker build --build-arg NEXT_PUBLIC_API_URL=https://dev.billages.com -t billage-fe .
```

**권장**: GitHub Actions에서 미리 빌드하여 ECR 푸시

#### 4.2.3 PM2 제거

**v1**: PM2로 Next.js 프로세스 관리 (systemd 감시)

**v2**: Docker가 프로세스 관리
- `--restart unless-stopped`: 컨테이너 crash 시 자동 재시작
- Docker health check 추가 (선택사항)

```yaml
healthcheck:
  test: ["CMD", "curl", "-f", "http://localhost:3000/"]
  interval: 30s
  timeout: 5s
  retries: 3
  start_period: 120s
```

#### 4.2.4 로그 수집

**v1**: /var/log/billage/frontend/

**v2**: Docker stdout → Promtail

```bash
docker run ... \
  --log-driver json-file \
  --log-opt max-size=10m \
  --log-opt max-file=3 \
  ...
```

**Promtail job 설정** (추후 05-logging-migration.md에서 상세)

```
job_name: frontend
static_configs:
  - targets: [localhost]
    labels:
      job: frontend
      service: billage-frontend
      environment: dev
```

#### 4.2.5 ALB Target Group Health Check

```
Protocol: HTTP
Path: /
Port: 3000
Interval: 30 seconds
Timeout: 5 seconds
Healthy threshold: 2
Unhealthy threshold: 3
Grace period: 120 seconds
Matcher: 200, 301, 302
```

### 4.3 AI (FastAPI) 마이그레이션

#### 4.3.1 Docker 이미지 설계

**Dockerfile**

```
FROM public.ecr.aws/lambda/python:3.10 as base
WORKDIR /app
COPY requirements.txt .
RUN pip install -r requirements.txt

FROM public.ecr.aws/lambda/python:3.10
WORKDIR /app
COPY --from=base /var/task /var/task
COPY --from=base /app/requirements.txt .
COPY . .
EXPOSE 5000
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "5000"]
```

**또는 Python 공식 이미지**

```
FROM python:3.10-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
EXPOSE 5000
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "5000"]
```

**이미지 크기 목표**: < 250MB

#### 4.3.2 Python 의존성 관리

**requirements.txt**
- 모든 패키지 버전 고정 (pip freeze)
- 예:
  ```
  fastapi==0.104.1
  uvicorn==0.24.0
  pydantic==2.5.0
  requests==2.31.0
  python-runpod==0.1.24
  ...
  ```

**멀티 스테이지 빌드**
- 빌드 스테이지: 컴파일 도구 포함
- 런타임 스테이지: 필수 라이브러리만 포함 (pip install 결과 카피)

#### 4.3.3 RunPod API Key 관리

**현재**: systemd EnvironmentFile에 저장 (보안 위험)

**v2**: AWS Secrets Manager 또는 SSM Parameter Store (암호화)

**권장: Secrets Manager**

```bash
# user_data_ai.sh.tpl
RUNPOD_API_KEY=$(aws secretsmanager get-secret-value \
  --secret-id /billage/dev/runpod-api-key \
  --query 'SecretString' \
  --output text)

docker run -d \
  --name billage-ai \
  -p 5000:5000 \
  -e RUNPOD_API_KEY="$RUNPOD_API_KEY" \
  --restart unless-stopped \
  ...
```

**또는 SSM Parameter (암호화 버전)**

```bash
RUNPOD_API_KEY=$(aws ssm get-parameter \
  --name /billage/dev/ai/runpod_api_key \
  --with-decryption \
  --query 'Parameter.Value' \
  --output text)
```

#### 4.3.4 Health Check

**FastAPI health endpoint 추가** (application에 이미 있다고 가정)

```python
from fastapi import FastAPI

app = FastAPI()

@app.get("/health")
async def health():
    return {"status": "ok"}
```

**ALB Target Group 설정**

```
Protocol: HTTP
Path: /health
Port: 5000
Interval: 30 seconds
Timeout: 5 seconds
Healthy threshold: 2
Unhealthy threshold: 3
Grace period: 120 seconds
Matcher: 200
```

#### 4.3.5 Uvicorn 워커 설정

**프로덕션 권장 설정**

```bash
CMD ["uvicorn", "main:app", \
     "--host", "0.0.0.0", \
     "--port", "5000", \
     "--workers", "2", \
     "--log-level", "info"]
```

**또는 user_data에서 override**

```bash
docker run ... \
  billage-ai:latest \
  uvicorn main:app --host 0.0.0.0 --port 5000 --workers 2
```

---

## 5. Docker 이미지 전략

### 5.1 이미지 크기 최적화

| 서비스 | 목표 | 최적화 전략 |
|--------|------|-----------|
| Backend | < 300MB | JRE only, 멀티스테이지 빌드, 캐시 레이어 최소화 |
| Frontend | < 200MB | node_modules 제외 (standalone), 정적 파일만 포함 |
| AI | < 250MB | pip --no-cache-dir, 멀티스테이지 빌드 |

### 5.2 태깅 전략

**ECR 이미지 태그**

```
753159922519.dkr.ecr.ap-northeast-2.amazonaws.com/billage-be:
├── 1.0.0-a1b2c3d (semantic versioning + git SHA)
├── 1.0.0 (semantic versioning only)
├── latest (rolling tag)
└── [deprecated] stable (롤백용 별도 태그는 불필요, Launch Template 버전 활용)
```

**GitHub Actions에서 태그 생성**

```bash
# workflow 예
VERSION=$(cat VERSION)
GIT_SHA=$(git rev-parse --short HEAD)
IMAGE_TAG="${VERSION}-${GIT_SHA}"
docker tag billage-be:latest 753159922519.dkr.ecr.ap-northeast-2.amazonaws.com/billage-be:$IMAGE_TAG
docker push 753159922519.dkr.ecr.ap-northeast-2.amazonaws.com/billage-be:$IMAGE_TAG
docker push 753159922519.dkr.ecr.ap-northeast-2.amazonaws.com/billage-be:latest
```

### 5.3 ECR 생명주기 정책

**목표**: 이미지 저장소 크기 관리, 네트워크 대역폭 절약

```json
{
  "rules": [
    {
      "rulePriority": 1,
      "description": "Keep 10 most recent images",
      "selection": {
        "tagStatus": "any",
        "countType": "imageCountMoreThan",
        "countNumber": 10
      },
      "action": {
        "type": "expire"
      }
    }
  ]
}
```

**Terraform (v2/envs/dev/main.tf)**

```hcl
resource "aws_ecr_lifecycle_policy" "billage_be" {
  repository = aws_ecr_repository.billage_be.name
  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep 10 most recent images"
        selection = {
          tagStatus     = "any"
          countType     = "imageCountMoreThan"
          countNumber   = 10
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}
```

### 5.4 취약점 스캔 (Vulnerability Scanning)

**ECR 자동 스캔**

```hcl
resource "aws_ecr_repository" "billage_be" {
  name = "billage-be"
  image_scanning_configuration {
    scan_on_push = true
  }
}
```

**스캔 결과 처리**
- Critical/High severity: 빌드 실패 (GitHub Actions에서)
- Medium/Low: 경고만 기록

### 5.5 빌드 캐시 전략

**Docker buildx + GitHub Actions cache**

```yaml
# .github/workflows/build-backend.yml
- name: Set up Docker Buildx
  uses: docker/setup-buildx-action@v2

- name: Build and push
  uses: docker/build-push-action@v5
  with:
    context: ./backend
    push: true
    tags: |
      753159922519.dkr.ecr.ap-northeast-2.amazonaws.com/billage-be:latest
      753159922519.dkr.ecr.ap-northeast-2.amazonaws.com/billage-be:${{ env.VERSION }}-${{ github.sha }}
    cache-from: type=registry,ref=753159922519.dkr.ecr.ap-northeast-2.amazonaws.com/billage-be:buildcache
    cache-to: type=registry,ref=753159922519.dkr.ecr.ap-northeast-2.amazonaws.com/billage-be:buildcache,mode=max
```

**.dockerignore 필수**

```
.env
.env.local
.env.*.local
.git
.gitignore
.github
node_modules
dist
build
target
__pycache__
.pytest_cache
.DS_Store
.vscode
*.log
*.swp
*.swo
```

---

## 6. 환경 변수 관리 전환

### 6.1 v1 vs v2 비교

| 항목 | v1 | v2 |
|------|----|----|
| **저장소** | .env 파일 + systemd EnvironmentFile | SSM Parameter Store + Secrets Manager |
| **주입 시점** | systemd 시작 시 | user_data 실행 시 (EC2 부팅 중) |
| **보안** | 파일 권한 의존 (root 읽기 가능) | IAM + 암호화 (별도 권한 체크) |
| **변경 반영** | systemctl restart (서비스 재시작) | ASG Instance Refresh |
| **감사 추적** | 없음 | CloudTrail에 기록 |

### 6.2 SSM Parameter Store 경로 규칙

**계층 구조**

```
/billage
├── /dev
│   ├── /backend
│   │   ├── db_host: rds-dev-instance.xxx.ap-northeast-2.rds.amazonaws.com
│   │   ├── db_port: 3306
│   │   ├── db_username: admin
│   │   ├── db_password: (String parameter, 암호화)
│   │   ├── jwt_secret: (String parameter, 암호화)
│   │   ├── redis_endpoint: redis-dev.xxx.ng.0001.apn2.cache.amazonaws.com
│   │   └── s3_bucket_name: billage-dev-bucket
│   ├── /frontend
│   │   ├── api_url: https://dev.billages.com
│   │   └── auth_domain: auth.dev.billages.com (미래용)
│   └── /ai
│       ├── runpod_api_key: (String parameter, 암호화)
│       └── model_version: 1.2.3
└── /prod
    └── (비슷한 구조)
```

### 6.3 user_data에서 SSM 조회

**Best Practice: 재시도 로직 포함**

```bash
#!/bin/bash
set -e

# Logging
exec > >(tee -a /var/log/user-data.log)
exec 2>&1

echo "[$(date)] Starting user_data script for backend"

# AWS CLI 설치 확인
if ! command -v aws &> /dev/null; then
    echo "[$(date)] Installing AWS CLI..."
    apt-get update
    apt-get install -y awscli
fi

# IAM Instance Profile 대기 (최대 10초)
for i in {1..10}; do
    if aws sts get-caller-identity > /dev/null 2>&1; then
        echo "[$(date)] IAM Instance Profile ready"
        break
    fi
    echo "[$(date)] Waiting for IAM Instance Profile ($i/10)..."
    sleep 1
done

# SSM Parameter 조회 (재시도 로직)
get_parameter() {
    local param_name=$1
    local max_retries=3
    local retry=0

    while [ $retry -lt $max_retries ]; do
        result=$(aws ssm get-parameter \
            --name "$param_name" \
            --with-decryption \
            --query 'Parameter.Value' \
            --output text \
            --region ap-northeast-2 2>/dev/null) && break

        retry=$((retry+1))
        echo "[$(date)] Failed to get $param_name, retrying ($retry/$max_retries)..."
        sleep 2
    done

    if [ -z "$result" ]; then
        echo "[$(date)] FATAL: Could not retrieve $param_name"
        exit 1
    fi

    echo "$result"
}

echo "[$(date)] Retrieving parameters from SSM..."
DB_PASSWORD=$(get_parameter "/billage/dev/backend/db_password")
JWT_SECRET=$(get_parameter "/billage/dev/backend/jwt_secret")
REDIS_ENDPOINT=$(get_parameter "/billage/dev/backend/redis_endpoint")

echo "[$(date)] Parameters retrieved successfully"

# Docker 설치 확인
if ! command -v docker &> /dev/null; then
    echo "[$(date)] Installing Docker..."
    apt-get update
    apt-get install -y docker.io
    systemctl start docker
    systemctl enable docker
fi

# ECR 로그인
echo "[$(date)] Logging in to ECR..."
aws ecr get-login-password --region ap-northeast-2 | \
    docker login --username AWS --password-stdin 753159922519.dkr.ecr.ap-northeast-2.amazonaws.com

# Docker 이미지 풀
echo "[$(date)] Pulling Docker image..."
docker pull 753159922519.dkr.ecr.ap-northeast-2.amazonaws.com/billage-be:latest

# Docker 컨테이너 실행
echo "[$(date)] Starting Docker container..."
docker run -d \
    --name billage-backend \
    -p 8080:8080 \
    -e SPRING_DATASOURCE_PASSWORD="$DB_PASSWORD" \
    -e SPRING_DATASOURCE_URL="jdbc:mysql://rds-dev-instance.xxx.ap-northeast-2.rds.amazonaws.com:3306/billage?useSSL=true" \
    -e JWT_SECRET="$JWT_SECRET" \
    -e SPRING_REDIS_HOST="$REDIS_ENDPOINT" \
    -e SPRING_REDIS_PORT="6379" \
    -e AWS_REGION="ap-northeast-2" \
    -e SPRING_PROFILES_ACTIVE="docker" \
    --restart unless-stopped \
    --log-driver json-file \
    --log-opt max-size=10m \
    --log-opt max-file=3 \
    --health-interval=30s \
    --health-timeout=5s \
    --health-retries=3 \
    --health-start-period=60s \
    753159922519.dkr.ecr.ap-northeast-2.amazonaws.com/billage-be:latest

echo "[$(date)] Waiting for container to be healthy..."
sleep 10

# Health check
if ! docker exec billage-backend curl -f http://localhost:8080/actuator/health; then
    echo "[$(date)] WARN: Initial health check failed, but container is running"
fi

echo "[$(date)] user_data script completed"
```

### 6.4 IAM 권한 (Instance Profile)

**필요한 권한**

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ssm:GetParameter",
        "ssm:GetParameters"
      ],
      "Resource": "arn:aws:ssm:ap-northeast-2:753159922519:parameter/billage/dev/*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "secretsmanager:GetSecretValue"
      ],
      "Resource": "arn:aws:secretsmanager:ap-northeast-2:753159922519:secret:/billage/dev/*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "ecr:GetAuthorizationToken"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "ecr:BatchGetImage",
        "ecr:GetDownloadUrlForLayer"
      ],
      "Resource": "arn:aws:ecr:ap-northeast-2:753159922519:repository/billage-*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject"
      ],
      "Resource": "arn:aws:s3:::billage-dev-bucket/*"
    }
  ]
}
```

### 6.5 민감 정보 암호화

**SSM Parameter (Secure String)**

```bash
aws ssm put-parameter \
  --name /billage/dev/backend/db_password \
  --value "your-secure-password" \
  --type "SecureString" \
  --key-id alias/aws/ssm \
  --region ap-northeast-2
```

**Secrets Manager (권장 for sensitive secrets)**

```bash
aws secretsmanager create-secret \
  --name /billage/dev/runpod-api-key \
  --secret-string "sk-xxxxxxxxxxxx" \
  --region ap-northeast-2
```

---

## 7. 로그 수집 전환

### 7.1 v1: 파일 기반 로깅

```
Backend:  /var/log/billage/backend/application.log → Promtail → Loki
Frontend: /var/log/billage/frontend/pm2.log → Promtail → Loki
AI:       /var/log/billage/ai/uvicorn.log → Promtail → Loki
```

**문제점**
- 수작업으로 파일 권한 관리 필수
- 로그 로테이션 설정 복잡 (logrotate)
- 컨테이너 메트릭 기록 불가

### 7.2 v2: Docker stdout/stderr → Promtail

**로그 드라이버 선택**

```
json-file: Docker 기본, JSON 형식, 호스트 디스크에 저장
  └─ 용점: 간단, 호스트 모니터링 가능
  └─ 단점: 로그 로테이션 수동 설정

awslogs: CloudWatch Logs로 직송
  └─ 용점: AWS 통합, 중앙 집중식
  └─ 단점: 인프라 관리 비용, 네트워크 지연

splunk: Splunk로 직송 (선택사항)

선택: json-file (로컬 저장) + Promtail (수집) → Loki 적합
```

### 7.3 Promtail 설정

**user_data에 Promtail 에이전트 추가**

```bash
# user_data에서 Promtail 설치
curl -fL https://github.com/grafana/loki/releases/download/v2.9.0/promtail-linux-amd64.zip -o /tmp/promtail.zip
unzip /tmp/promtail.zip -d /usr/local/bin
chmod +x /usr/local/bin/promtail-linux-amd64

# promtail-config.yaml 생성
cat > /etc/promtail/config.yaml << 'EOF'
clients:
  - url: http://loki.internal:3100/loki/api/v1/push

positions:
  filename: /tmp/positions.yaml

scrape_configs:
  - job_name: billage-backend
    docker_sd_configs:
      - host: unix:///var/run/docker.sock
        refresh_interval: 5s
    relabel_configs:
      - source_labels: ['__meta_docker_container_name']
        target_label: container
      - source_labels: ['__meta_docker_container_id']
        target_label: container_id
    pipeline_stages:
      - json:
          expressions:
            log: log
      - output:
          source: log
EOF

# Promtail 실행 (systemd)
systemctl start promtail
systemctl enable promtail
```

**라벨링 전략**

```yaml
pipeline_stages:
  - labels:
      service: billage-backend  # 또는 frontned, ai
      environment: dev
      instance_id: $(ec2-metadata --instance-id)
      region: ap-northeast-2
```

### 7.4 로그 보관 정책

```
실시간 수집: Docker stdout → Promtail → Loki (retention: 7 days)
장기 보관: CloudWatch Logs → S3 (lifecycle policy: 90 days)
```

---

## 8. 모니터링 에이전트 (현재 user_data에 빠진 부분)

### 8.1 현재 상태

**v1에서 구축됨**: Node Exporter (시스템 메트릭만)

**v2에서 추가 필요**: cAdvisor (컨테이너 메트릭), Promtail (로그 수집)

### 8.2 Node Exporter 유지

```bash
# user_data에 추가
apt-get install -y prometheus-node-exporter
systemctl start prometheus-node-exporter
systemctl enable prometheus-node-exporter

# Exporter가 listen하는 포트: 9100
# Prometheus scrape config:
#   - job_name: 'node'
#     static_configs:
#       - targets: ['localhost:9100']
#         labels:
#           service: billage-backend
```

### 8.3 cAdvisor (Container Advisor) 추가

**목표**: Docker 컨테이너의 CPU, Memory, Network I/O 메트릭 수집

```bash
# user_data에서 cAdvisor 컨테이너 실행
docker run -d \
  --name=cadvisor \
  --volume=/:/rootfs:ro \
  --volume=/var/run:/var/run:ro \
  --volume=/sys:/sys:ro \
  --volume=/var/lib/docker/:/var/lib/docker:ro \
  --volume=/dev/disk/:/dev/disk:ro \
  --publish=8080:8080 \
  --detach=true \
  gcr.io/cadvisor/cadvisor:latest
```

**주의**: Backend가 port 8080을 쓰므로 충돌
**해결**: cAdvisor를 다른 포트에 바인딩

```bash
docker run -d \
  --name=cadvisor \
  ...
  --publish=8081:8080 \
  gcr.io/cadvisor/cadvisor:latest
```

**Prometheus scrape config**

```yaml
- job_name: 'cadvisor'
  static_configs:
    - targets: ['localhost:8081']
      labels:
        service: billage-backend
        metric_type: container
```

### 8.4 Promtail (로그 수집)

**위 7.3 참조**

### 8.5 user_data 최종 체크리스트

```
[ ] AWS CLI 설치 & IAM Instance Profile 확인
[ ] Docker 설치 & daemon 시작
[ ] Node Exporter 설치 (systemd)
[ ] cAdvisor 컨테이너 시작 (port 8081)
[ ] Promtail 설치 & 시작 (config 포함)
[ ] SSM Parameter 조회 & 검증
[ ] ECR 로그인
[ ] 애플리케이션 컨테이너 시작
[ ] Health check 검증
[ ] 로그 수집 검증 (Promtail 정상 작동)
[ ] 메트릭 수집 검증 (Node Exporter, cAdvisor 응답)
```

---

## 9. S3 연동 변경점

### 9.1 IAM Instance Profile 유지

**v1 & v2 모두**

```hcl
# Terraform
resource "aws_iam_role" "billage_ec2_role" {
  name = "billage-ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy" "billage_s3_access" {
  role = aws_iam_role.billage_ec2_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "s3:GetObject",
        "s3:PutObject"
      ]
      Resource = "arn:aws:s3:::billage-dev-bucket/*"
    }]
  })
}
```

### 9.2 IMDSv2 + hop_limit=2 Docker 대응

**문제**: Docker 컨테이너는 host의 IMDS (169.254.169.254)에 접근 필요

**IMDSv2 설정**
```hcl
metadata_options {
  http_endpoint           = "enabled"
  http_tokens             = "required"  # IMDSv2 강제
  http_put_response_hop_limit = 2       # 컨테이너에서 접근 가능
}
```

**hop_limit=2 의미**
- hop_limit=1: EC2 인스턴스 자신만 IMDS 접근 가능
- hop_limit=2: EC2 인스턴스 + 로컬 네트워크 (컨테이너 포함)

**Docker 컨테이너에서 S3 접근**

```bash
# Container 내부
aws s3 ls s3://billage-dev-bucket/

# Spring Boot에서 presigned URL 생성
// src/main/java/com/billage/service/S3Service.java
@Service
public class S3Service {
    private final S3Client s3Client;

    public String generatePresignedUrl(String key) {
        GetObjectRequest getObjectRequest = GetObjectRequest.builder()
            .bucket("billage-dev-bucket")
            .key(key)
            .build();

        GetObjectPresigner presigner = S3Presigner.builder()
            .region(Region.AP_NORTHEAST_2)
            .build()
            .getObjectPresigner();

        PresignedGetObjectRequest presignedRequest = presigner.presignGetObject(r -> r
            .getObjectRequest(getObjectRequest)
            .signatureDuration(Duration.ofMinutes(15))
        );

        return presignedRequest.url().toString();
    }
}
```

**변경점 없음**: 로직은 동일, IAM 권한만 확인

### 9.3 VPC Endpoint (성능 최적화)

**선택사항 but 권장** (NAT 경유 대역폭 절감)

```hcl
resource "aws_vpc_endpoint" "s3" {
  vpc_id       = aws_vpc.main.id
  service_name = "com.amazonaws.ap-northeast-2.s3"
  route_table_ids = [aws_route_table.private.id]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = "*"
      Action = "s3:*"
      Resource = "*"
    }]
  })
}
```

---

## 10. CI/CD 파이프라인 전환

### 10.1 v1 Pipeline (기존)

```
GitHub Push
    ↓
GitHub Actions: build-backend.yml (paths: backend/**)
    ├── Maven build → JAR
    ├── SCP → EC2:/opt/billage/backend/target/
    ├── SSH → systemctl restart billage-backend
    └── restart 대기 (10초)
```

**문제점**
- SCP/SSH에 의존 (인증서 관리)
- 재시작 중에 요청 실패 가능
- 배포 실패 시 수동 개입 필요

### 10.2 v2 Pipeline (신규)

```
GitHub Push (backend/** 변경)
    ↓
GitHub Actions: build-backend.yml
    ├── Setup OIDC → AWS credentials (임시)
    ├── AWS ECR login
    ├── Docker build (multi-stage, ARM64)
    │   ├── Cache: ghcr.io/billage/billage-be:buildcache
    │   └── Output: billage-be:1.0.0-abc1234
    ├── Docker push → ECR (753159922519.dkr.ecr.ap-northeast-2.amazonaws.com/billage-be)
    ├── ECR scan on push (vulnerability detection)
    ├── Update Launch Template
    │   └── user_data 업데이트 (image latest tag)
    └── Trigger ASG Instance Refresh
        ├── MinHealthyPercentage: 90%
        ├── Instance replacement 시작
        ├── 기존 인스턴스 1개 보존
        ├── 새 인스턴스 시작
        ├── Health check (240s grace period)
        ├── ALB Target Group 등록
        └── 기존 인스턴스 graceful drain (60s)

결과: 무중단 배포 (zero-downtime deployment)
```

### 10.3 GitHub Actions OIDC 설정

**목표**: SCP/SSH key 제거, OIDC로 임시 AWS 자격증명 사용

```yaml
# .github/workflows/build-backend.yml
name: Build and Deploy Backend

on:
  push:
    branches: [main, dev]
    paths:
      - 'backend/**'
      - '.github/workflows/build-backend.yml'

permissions:
  contents: read
  id-token: write  # OIDC token 요청 권한

env:
  AWS_REGION: ap-northeast-2
  ECR_REGISTRY: 753159922519.dkr.ecr.ap-northeast-2.amazonaws.com
  ECR_REPOSITORY: billage-be

jobs:
  build-and-deploy:
    runs-on: ubuntu-latest

    steps:
      - name: Checkout code
        uses: actions/checkout@v4

      - name: Configure AWS credentials via OIDC
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::753159922519:role/github-actions-oidc-role
          aws-region: ap-northeast-2

      - name: Login to ECR
        run: |
          aws ecr get-login-password --region ${{ env.AWS_REGION }} | \
            docker login --username AWS --password-stdin ${{ env.ECR_REGISTRY }}

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v2

      - name: Extract metadata
        id: meta
        run: |
          VERSION=$(cat backend/VERSION)
          GIT_SHA=$(git rev-parse --short HEAD)
          echo "image-tag=${VERSION}-${GIT_SHA}" >> $GITHUB_OUTPUT
          echo "latest-tag=latest" >> $GITHUB_OUTPUT

      - name: Build and push Docker image
        uses: docker/build-push-action@v5
        with:
          context: ./backend
          push: true
          tags: |
            ${{ env.ECR_REGISTRY }}/${{ env.ECR_REPOSITORY }}:${{ steps.meta.outputs.image-tag }}
            ${{ env.ECR_REGISTRY }}/${{ env.ECR_REPOSITORY }}:${{ steps.meta.outputs.latest-tag }}
          cache-from: type=registry,ref=${{ env.ECR_REGISTRY }}/${{ env.ECR_REPOSITORY }}:buildcache
          cache-to: type=registry,ref=${{ env.ECR_REGISTRY }}/${{ env.ECR_REPOSITORY }}:buildcache,mode=max
          build-args: |
            JAVA_OPTS=-Xms800m -Xmx1200m -XX:+UseG1GC

      - name: Update Launch Template
        run: |
          # 최신 Launch Template 버전 조회
          LT_ID=$(aws ec2 describe-launch-templates \
            --launch-template-names lt-billage-backend-v1 \
            --query 'LaunchTemplates[0].LaunchTemplateId' \
            --output text)

          LT_VERSION=$(aws ec2 describe-launch-template-versions \
            --launch-template-id $LT_ID \
            --query 'LaunchTemplateVersions[0].VersionNumber' \
            --output text)

          # 새 버전 생성 (user_data 업데이트)
          aws ec2 create-launch-template-version \
            --launch-template-id $LT_ID \
            --source-version $LT_VERSION \
            --launch-template-data '{
              "UserData": "...base64 encoded user_data with latest tag..."
            }'

      - name: Trigger ASG Instance Refresh
        run: |
          ASG_NAME="asg-billage-backend-dev"
          aws autoscaling start-instance-refresh \
            --auto-scaling-group-name $ASG_NAME \
            --preferences '{
              "MinHealthyPercentage": 90,
              "InstanceWarmupSeconds": 240,
              "CheckpointPercentages": [50],
              "CheckpointDelay": 300
            }'

      - name: Wait for Instance Refresh to complete
        run: |
          ASG_NAME="asg-billage-backend-dev"

          # 최대 30분 대기
          for i in {1..60}; do
            STATUS=$(aws autoscaling describe-instance-refreshes \
              --auto-scaling-group-name $ASG_NAME \
              --query 'InstanceRefreshes[0].Status' \
              --output text)

            if [ "$STATUS" = "Successful" ]; then
              echo "Instance Refresh completed successfully"
              exit 0
            elif [ "$STATUS" = "Failed" ] || [ "$STATUS" = "Cancelled" ]; then
              echo "Instance Refresh failed with status: $STATUS"
              exit 1
            fi

            echo "Instance Refresh in progress... (Status: $STATUS)"
            sleep 30
          done

          echo "Timeout waiting for Instance Refresh"
          exit 1
```

### 10.4 AWS IAM OIDC Provider 설정 (일회성)

```hcl
# terraform/oidc.tf
resource "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"

  client_id_list = ["sts.amazonaws.com"]

  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]  # GitHub Actions thumbprint
}

resource "aws_iam_role" "github_actions_role" {
  name = "github-actions-oidc-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = aws_iam_openid_connect_provider.github.arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        StringLike = {
          "token.actions.githubusercontent.com:sub" = "repo:billage-dev/billage:*"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "github_actions_policy" {
  role = aws_iam_role.github_actions_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken",
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer",
          "ecr:PutImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload"
        ]
        Resource = "arn:aws:ecr:ap-northeast-2:753159922519:repository/billage-*"
      },
      {
        Effect = "Allow"
        Action = [
          "ec2:DescribeLaunchTemplates",
          "ec2:DescribeLaunchTemplateVersions",
          "ec2:CreateLaunchTemplateVersion"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "autoscaling:StartInstanceRefresh",
          "autoscaling:DescribeInstanceRefreshes"
        ]
        Resource = "arn:aws:autoscaling:ap-northeast-2:753159922519:autoScalingGroup:*:autoScalingGroupName/asg-billage-*"
      }
    ]
  })
}
```

### 10.5 Instance Refresh 상세

**원리**

```
1. MinHealthyPercentage=90% → 최소 90% 인스턴스 health 유지
2. 기존: 1개 인스턴스 → 0.9 * 1 = 0.9 ≈ 1개 유지 필수
3. 새 인스턴스 시작 (ASG desired 임시 증가 가능)
4. Health check 통과 → ALB Target Group 등록
5. 기존 인스턴스 connection draining (60s)
6. 기존 인스턴스 termination
```

**CheckpointPercentages 활용** (부분 배포 검증)

```bash
aws autoscaling start-instance-refresh \
  --auto-scaling-group-name asg-billage-backend-dev \
  --preferences '{
    "MinHealthyPercentage": 90,
    "InstanceWarmupSeconds": 240,
    "CheckpointPercentages": [50],
    "CheckpointDelay": 300
  }'
```

- 50% 배포 후 5분 대기 (모니터링)
- 문제 없으면 자동 진행
- 문제 발생 시 `CancelInstanceRefresh` 호출 가능

### 10.6 롤백 전략

**시나리오**: 새 이미지에 버그 발견

```bash
# 방법 1: Instance Refresh 취소
aws autoscaling cancel-instance-refresh \
  --auto-scaling-group-name asg-billage-backend-dev

# 방법 2: 이전 Launch Template 버전으로 되돌리기
LT_ID="lt-xxxxx"
PREVIOUS_VERSION=42  # 이전 버전

aws autoscaling update-auto-scaling-group \
  --auto-scaling-group-name asg-billage-backend-dev \
  --launch-template LaunchTemplateId=$LT_ID,Version=$PREVIOUS_VERSION

# 새로운 Instance Refresh 시작
aws autoscaling start-instance-refresh \
  --auto-scaling-group-name asg-billage-backend-dev
```

---

## 11. 실행 계획 (Phase별)

### 11.1 Phase 0: 사전 준비 (1주)

```
[ ] Terraform v2/envs/dev/main.tf 검토 & 수정
    ├─ ASG desired 값 재검토 (초기: BE=1, FE=1, AI=1)
    ├─ Health check 경로/타임아웃 재확인
    └─ SG 규칙 & IAM 권한 검토

[ ] Docker 이미지 Dockerfile 작성
    ├─ Backend: multi-stage, JRE, ARM64
    ├─ Frontend: standalone mode, NEXT_PUBLIC_API_URL
    └─ AI: Python dependencies, RunPod API key

[ ] user_data 템플릿 작성 & 검증
    ├─ user_data_backend.sh.tpl
    ├─ user_data_frontend.sh.tpl
    └─ user_data_ai.sh.tpl

[ ] SSM Parameter Store 설정
    ├─ 모든 /billage/dev/* 파라미터 등록
    ├─ Secrets Manager에 민감 정보 (RunPod API Key)
    └─ IAM 권한 확인

[ ] GitHub Actions Workflow 작성
    ├─ build-backend.yml (Docker build → ECR → Instance Refresh)
    ├─ build-frontend.yml
    └─ build-ai.yml

[ ] 테스트 인스턴스 생성 & 검증
    ├─ 수동으로 EC2 1개 생성 (Docker 테스트)
    ├─ 모든 서비스 동작 확인
    └─ 로그 수집 & 메트릭 확인
```

### 11.2 Phase 1: Docker 이미지 빌드 & ECR 푸시 (1주)

```
[ ] ECR 저장소 생성 (이미 생성됨)
    └─ billage-be, billage-fe, billage-ai

[ ] 첫 빌드: 로컬 또는 GitHub Actions (300K MAU 기준)
    ├─ Backend:
    │  ├─ docker build -t billage-be:1.0.0-abc1234 .
    │  ├─ Dockerfile: JVM 튜닝 (-Xms800m -Xmx1000m for 900 RPS)
    │  ├─ 이미지 크기: ~250-280MB (target)
    │  ├─ docker push
    │  └─ ECR 스캔 통과 확인
    ├─ Frontend: 동일 (NEXT_PUBLIC_API_URL 빌드 타임 주입)
    └─ AI: 동일 (RunPod API Key 처리)

[ ] 이미지 검증 (300K MAU 스트레스 테스트)
    ├─ 테스트 인스턴스 (t4g.small) 생성
    ├─ docker pull & run
    ├─ Application 정상 시작 확인
    ├─ Health check 응답 확인 (< 240s)
    ├─ 간단한 부하 테스트: 100 RPS, 1분
    │  └─ 메모리 사용량 < 80%
    │  └─ 응답시간 < 100ms (p95)
    └─ 로그 수집 확인 (Promtail)
```

**이 단계에서는 v1 서비스 중단 없음** (ECR에만 이미지 저장)

### 11.3 Phase 2: Backend ASG 생성 & 테스트 (1주)

```
[ ] Terraform apply (Backend ASG만)
    ├─ terraform apply -target=aws_autoscaling_group.backend
    ├─ terraform apply -target=aws_lb_target_group.backend
    └─ 기본 설정으로 진행 (아직 트래픽 전환 X)

[ ] ASG 인스턴스 검증
    ├─ EC2 Console에서 인스턴스 상태 확인
    ├─ ALB Target Group: "Healthy" 상태 확인 (2-3분 소요)
    ├─ SSH 접속: ssh -i key.pem ubuntu@{instance-ip}
    └─ 컨테이너 상태: docker ps

[ ] 애플리케이션 동작 검증
    ├─ curl http://{ALB-DNS}/api/actuator/health (API 응답)
    ├─ Spring Boot 로그 확인: docker logs billage-backend
    └─ 메트릭 수집 확인: curl http://{instance-ip}:9100/metrics

[ ] 데이터베이스 연동 검증
    ├─ 로그에서 DB 연결 성공 메시지 확인
    ├─ RDS 보안그룹: EC2 ASG SG 허용 재확인
    └─ (필요시) SELECT * FROM {table} LIMIT 1 쿼리 실행

[ ] 부하 테스트 (간단)
    ├─ k6 스크립트: 100 RPS, 5분
    ├─ 응답시간: p50 < 100ms, p95 < 300ms, p99 < 1000ms
    └─ 에러율: < 0.1%

[ ] Scale-out 테스트
    ├─ 부하 증가: 500 RPS (5분)
    ├─ CPU 증가 → 70% 도달 시 자동 scale-out 확인
    ├─ 새 인스턴스 2개 추가 (asg desired=3)
    ├─ ALB Target Group에 자동 등록 확인
    └─ 응답시간 개선 확인

[ ] Scale-in 테스트
    ├─ 부하 제거 → CPU 20%로 감소
    ├─ 1-2분 후 자동 scale-in (desired=1)
    ├─ Graceful drain 확인 (기존 연결 처리 후 종료)
    └─ 응답 중단 없음 확인

[ ] v2 전용 테스트 도메인 구성 (선택사항)
    ├─ Route53: api-v2.dev.billages.com → ALB DNS
    └─ 나머지 트래픽은 v1 유지 (v1.dev.billages.com)
```

**이 단계 완료 후**:
- Backend v2 = 완전 정상 작동
- v1 기존 트래픽 100% 유지
- v1과 v2 병렬 운영 가능

### 11.4 Phase 3: Frontend & AI ASG 생성 (1주)

```
[ ] Frontend ASG 생성
    ├─ Terraform apply -target=aws_autoscaling_group.frontend
    ├─ 검증: ALB → / (Next.js)
    └─ E2E: 홈페이지 로드 확인

[ ] AI ASG 생성
    ├─ Terraform apply -target=aws_autoscaling_group.ai
    ├─ 검증: ALB → /ai/health
    └─ E2E: 추천 API 호출 확인
```

### 11.5 Phase 4: E2E 통합 테스트 (1주)

**테스트 도메인**: https://v2.dev.billages.com

```
[ ] 회원가입 & 로그인
    ├─ POST /api/auth/signup
    ├─ GET /api/auth/login
    └─ JWT token 반환 확인

[ ] 물품 등록 (S3 업로드)
    ├─ POST /api/items (이미지 포함)
    ├─ S3 presigned URL 발급 확인
    ├─ 이미지 업로드 성공
    └─ 물품 조회 시 이미지 URL 확인

[ ] 채팅
    ├─ WebSocket 연결
    ├─ 메시지 송수신
    └─ Redis 캐시 작동 확인

[ ] AI 추천
    ├─ POST /ai/recommend
    ├─ RunPod 호출 확인
    └─ 추천 결과 반환

[ ] 부하 테스트 (최종)
    ├─ k6: 900 RPS, 10분
    ├─ p95 latency < 500ms
    ├─ p99 latency < 1000ms
    ├─ Error rate < 0.1%
    └─ Backend/Frontend/AI 각각 scale-out 확인

[ ] 모니터링 대시보드
    ├─ Grafana: CPU, Memory, RPS, Latency
    ├─ Loki: 로그 검색 (grep service=billage-backend)
    └─ Prometheus: 메트릭 쿼리
```

### 11.6 Phase 5: 트래픽 전환 (별도 문서: 05-lb-traffic-migration.md)

```
[ ] 트래픽 점진적 전환
    ├─ v2 비중: 10% → 25% → 50% → 75% → 100%
    ├─ 각 단계마다 모니터링 (1시간 유지)
    └─ 에러 발생 시 즉시 롤백

[ ] v1 서비스 종료
    └─ 모든 트래픽 v2로 전환 확인 후 v1 ASG 폐기
```

---

## 12. 검증 방법

### 12.1 ASG & 인스턴스 검증

```bash
# ASG 상태 확인
aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names asg-billage-backend-dev \
  --query 'AutoScalingGroups[0].[DesiredCapacity,MinSize,MaxSize,Instances[].InstanceId]' \
  --output table

# 인스턴스 상태 확인
aws ec2 describe-instances \
  --instance-ids i-0123456789abcdef0 \
  --query 'Reservations[0].Instances[0].[InstanceId,State.Name,PublicIpAddress]' \
  --output table

# SSM 세션으로 접속 (SSH key 불필요)
aws ssm start-session --target i-0123456789abcdef0
```

### 12.2 Docker 컨테이너 검증

```bash
# 컨테이너 실행 상태
docker ps --filter "name=billage"

# 컨테이너 로그
docker logs billage-backend | head -50
docker logs --follow billage-backend

# 컨테이너 리소스 사용량
docker stats billage-backend

# 컨테이너 내부 파일 확인
docker exec billage-backend ls -la /app
docker exec billage-backend ps aux
```

### 12.3 ALB Target Group 검증

```bash
# Target 상태
aws elbv2 describe-target-health \
  --target-group-arn arn:aws:elasticloadbalancing:... \
  --query 'TargetHealthDescriptions[*].[Target.Id,TargetHealth.State,TargetHealth.Description]' \
  --output table

# Health check 성공 로그 (CloudWatch)
aws logs tail /aws/elasticloadbalancing/app/... --follow
```

### 12.4 E2E API 테스트

```bash
# Health check
curl -v http://v2.dev.billages.com/api/actuator/health

# 회원가입
curl -X POST http://v2.dev.billages.com/api/auth/signup \
  -H "Content-Type: application/json" \
  -d '{"email":"test@example.com","password":"password123"}'

# 물품 등록
curl -X POST http://v2.dev.billages.com/api/items \
  -H "Authorization: Bearer {token}" \
  -F "name=test-item" \
  -F "image=@image.jpg"

# AI 추천
curl http://v2.dev.billages.com/ai/recommend \
  -H "Authorization: Bearer {token}"
```

### 12.5 부하 테스트 (k6)

```javascript
// k6-test.js
import http from 'k6/http';
import { check, sleep } from 'k6';

export const options = {
  stages: [
    { duration: '2m', target: 100 },
    { duration: '3m', target: 500 },
    { duration: '2m', target: 900 },
    { duration: '2m', target: 500 },
    { duration: '1m', target: 0 },
  ],
  thresholds: {
    http_req_duration: ['p(95)<500', 'p(99)<1000'],
    http_req_failed: ['rate<0.001'],
  },
};

export default function () {
  const res = http.get('http://v2.dev.billages.com/api/items');

  check(res, {
    'status is 200': (r) => r.status === 200,
    'response time < 500ms': (r) => r.timings.duration < 500,
  });

  sleep(1);
}
```

```bash
k6 run k6-test.js --out json=results.json
```

### 12.6 모니터링 대시보드 검증

```
Prometheus targets:
  └─ Backend:9100 (Node Exporter) ✓
  └─ Backend:8081 (cAdvisor) ✓
  └─ Frontend:9100 ✓
  └─ Frontend:8081 ✓
  └─ AI:9100 ✓
  └─ AI:8081 ✓

Loki logs (쿼리 예):
  └─ {service="billage-backend"} | json
  └─ {service="billage-frontend"} | json
  └─ {service="billage-ai"} | json

Grafana 대시보드:
  ├─ Overview: 서비스별 CPU, Memory, RPS, Error Rate
  ├─ Backend: JVM heap usage, GC pause, DB pool
  ├─ Frontend: Response time distribution
  └─ AI: Queue depth, Processing latency
```

---

## 13. Fallback & 롤백

### 13.1 배포 실패 시나리오

| 시나리오 | 증상 | 해결 |
|---------|------|-----|
| **ECR 이미지 pull 실패** | Target Health: unhealthy, health check timeout | 이미지 재빌드 & 푸시, Instance Refresh 재시작 |
| **user_data 실행 실패** | Instance running이지만 app 미동작 | user_data 로그 확인 (/var/log/user-data.log), SSH 접속 후 수동 디버깅 |
| **SSM Parameter not found** | Docker 시작 실패, exit code 1 | Parameter 등록 확인, IAM 권한 재확인 |
| **DB 연결 실패** | Spring Boot 로그: "Cannot get a connection" | RDS 보안그룹 확인, 암호 재확인 |
| **Health check 타임아웃** | 240초 grace period 초과 | JVM heap 크기 조정 (-Xmx 감소), 초기화 로직 최적화 |

### 13.2 Instance Refresh 취소

```bash
# 진행 중인 refresh 취소
aws autoscaling cancel-instance-refresh \
  --auto-scaling-group-name asg-billage-backend-dev

# 기존 인스턴스는 그대로 유지됨 (트래픽 계속 처리)
```

### 13.3 Launch Template 버전 롤백

```bash
# 이전 버전으로 ASG 구성 변경
LT_ID="lt-0123456789abcdef0"
PREVIOUS_VERSION=42

aws autoscaling update-auto-scaling-group \
  --auto-scaling-group-name asg-billage-backend-dev \
  --launch-template LaunchTemplateId=$LT_ID,Version=$PREVIOUS_VERSION

# 새로운 Instance Refresh 시작 (이전 버전 이미지로)
aws autoscaling start-instance-refresh \
  --auto-scaling-group-name asg-billage-backend-dev
```

### 13.4 v1 복구

**v2 완전 실패 시**:

```hcl
# Terraform에서 v2 ASG 비활성화
resource "aws_autoscaling_group" "backend" {
  enabled = false  # 또는 destroy
}

# ALB target group에서 v2 제거
aws elbv2 deregister-targets \
  --target-group-arn arn:aws:elasticloadbalancing:... \
  --targets Id=i-0123456789abcdef0

# v1의 기존 EC2 (t4g.medium)로 트래픽 복구
# systemctl start billage-backend (이미 실행 중)
```

---

## 14. 리스크 분석

### 14.1 기술적 리스크

| 리스크 | 심각도 | 발생 확률 | 완화 방법 |
|--------|--------|---------|---------|
| **JVM Cold Start** | 중간 | 높음 | Xms=800m, Xmx=1000m (900 RPS), 240s grace |
| **Docker image pull 느림** | 낮음 | 중간 | VPC Endpoint for ECR (선택사항) |
| **user_data 실패** | 높음 | 중간 | 재시도 로직, 로그 저장 (/var/log/user-data.log) |
| **메모리 부족** | 높음 | 중간 | Xmx=1000m 제한 필수, 모니터링 매우 중요 |
| **Graceful shutdown 실패** | 중간 | 낮음 | Docker --restart unless-stopped, ALB 60s drain |
| **SSM Parameter 조회 지연** | 낮음 | 낮음 | 캐싱 고려 (초기 조회만) |

### 14.2 성능 리스크

**메모리 분석: t4g.small (2GB) - 300K MAU (900 RPS)**

```
가용 메모리: 2048MB
├── OS (Linux kernel): 300MB
├── Docker daemon: 100MB
├── Node Exporter: 20MB
├── cAdvisor: 50MB
├── Promtail: 30MB
├── 애플리케이션 컨테이너: ~1,500MB
│   ├── Spring Boot JVM (900 RPS):
│   │   ├── Xmx1000m: 1000MB (heap, 안전)
│   │   ├── Xms800m: 800MB (초기, 빠른 할당)
│   │   ├── metaspace: 256MB
│   │   ├── off-heap (NIO buffers): 100MB
│   │   └── 소계: ~1,156MB (안전)
│   ├── 시스템 라이브러리: 30MB
│   └── 여유: ~300MB (안전)
└── 여유: ~18MB (최소 안전선)
```

**300K MAU 튜닝 결론**:
- `Xmx=1000m` 필수 (1200m은 위험!)
- 부하 모니터링: 메모리 사용률 > 85% → 인스턴스 재시작 또는 스케일 아웃
- 선택: Node Exporter/cAdvisor 호스트 별도 인스턴스로 분리 (고급)
- 긴급: 메모리 부족 시 t4g.medium (4GB) 업그레이드

### 14.3 운영 리스크

| 리스크 | 설명 | 완화 |
|--------|------|-----|
| **파이프라인 복잡도** | GitHub Actions OIDC, Terraform, Instance Refresh 조합 | 문서화, 테스트 자동화 |
| **롤백 절차 미숙** | 긴급 상황에서 수동 조작 오류 | 롤백 playbook 미리 준비 |
| **모니터링 데이터 부재** | 문제 발생 시 진단 어려움 | Phase 4에서 대시보드 완성 |

---

## 15. 리소스 및 일정 요약

### 15.1 전체 일정

| Phase | 기간 | 담당 | 산출물 |
|-------|------|------|--------|
| 0: 사전 준비 | 1주 | 인프라 팀 | Terraform, Dockerfile, workflow |
| 1: Docker 이미지 | 1주 | Dev + Infra | ECR에 3개 이미지 |
| 2: Backend ASG | 1주 | Infra + QA | v2 Backend 운영 확인 |
| 3: Frontend/AI ASG | 1주 | Infra | v2 모든 서비스 구성 |
| 4: E2E & 부하테스트 | 1주 | QA + Dev | 검증 보고서 |
| 5: 트래픽 전환 | 1-2일 | Infra + Ops | v2 100% 트래픽 |
| **총계** | **6-7주** | 소규모 팀 | **마이그레이션 완료** |

### 15.2 인프라 비용 추정

```
v1 현황:
  └─ EC2 t4g.medium: ~$40/month

v2 목표 (300K MAU 최대 확장 시):
  ├─ Backend ASG: t4g.small x 6 = ~$45/month (평균 3 instances @ 900 RPS)
  ├─ Frontend ASG: t4g.small x 3 = ~$22.5/month (평균 2 instances)
  ├─ AI ASG: t4g.small x 2 = ~$15/month (평균 1 instance)
  ├─ ALB: ~$20/month
  ├─ RDS db.t4g.small: ~$30/month (별도)
  ├─ ElastiCache cache.t4g.small: ~$15/month (권장, Pub/Sub)
  ├─ ECR: ~$5/month
  └─ 월 총: ~$150/month (v1 대비 3배, 300K MAU 확장성 & 안정성)
```

**절감 가능성**: 평상시 ASG desired 값을 2/2/1로 유지하면 ~$80/month
**주의**: 300K MAU는 최소 Backend 2개 필수 (health check, failover)

---

## 16. 체크리스트 (마이그레이션 최종 검증)

```
배포 파이프라인:
  [ ] GitHub Actions OIDC 작동
  [ ] Docker build & ECR push 자동화
  [ ] Instance Refresh 트리거 작동
  [ ] Rollback 절차 테스트

인프라:
  [ ] ALB + 3개 Target Group 구성
  [ ] 3개 ASG 구성 (min, max, desired 값 확인)
  [ ] Security Group 규칙 (포트, CIDR)
  [ ] IAM Role & Policy (EC2, GitHub Actions)
  [ ] VPC Endpoint (S3, ECR) 선택사항 구성

애플리케이션:
  [ ] Backend: health check 240초 내 응답
  [ ] Frontend: NEXT_PUBLIC_API_URL 정확
  [ ] AI: /health endpoint 구현
  [ ] 모든 서비스: Docker 헬스 체크 포함

환경 변수:
  [ ] SSM Parameter 모두 등록
  [ ] IAM 권한으로 조회 가능 확인
  [ ] user_data 스크립트 재시도 로직

모니터링:
  [ ] Node Exporter 메트릭 수집
  [ ] cAdvisor 컨테이너 메트릭 수집
  [ ] Promtail 로그 수집
  [ ] Grafana 대시보드 완성

테스트:
  [ ] E2E 회원가입 → 로그인 → 물품등록 → 조회
  [ ] 부하 테스트 900 RPS, p95 < 500ms
  [ ] Scale-out/Scale-in 자동화 검증
  [ ] 롤백 테스트 (Launch Template 버전 변경)

문서화:
  [ ] 운영 가이드 (서비스 재시작, 스케일링)
  [ ] 긴급 대응 (문제 진단, 롤백 절차)
  [ ] 모니터링 쿼리 (Prometheus, Loki)
  [ ] 배포 스크린샷 & 메트릭 기록

트래픽 전환:
  [ ] v2 테스트 도메인 구성 (v2.dev.billages.com)
  [ ] 로드 밸런싱 규칙 설정
  [ ] 점진적 트래픽 전환 계획 (10% → 100%)
  [ ] v1 폐기 절차 준비
```

---

## 결론

본 WAS 마이그레이션은 **단순한 서버 전환을 넘어 배포 자동화, 확장성, 모니터링을 전면 개선**하는 전략적 프로젝트이다.

### 핵심 성과
1. **무중단 배포**: Instance Refresh로 graceful shutdown 구현
2. **자동 확장**: 서비스별 독립 ASG로 효율적 스케일링
3. **운영 개선**: 파일 기반 로깅 → Docker stdout → Loki 중앙 집중식
4. **보안 강화**: SCP/SSH 제거 → OIDC, SSM Parameter 암호화
5. **재해 대응**: Launch Template 버전 관리로 신속한 롤백

### 성공 조건
- **메모리 제약** (t4g.small 2GB)을 항상 염두 (JVM Xmx 조정)
- **user_data 로그** 확인 습관 (첫 배포 시 필수)
- **점진적 트래픽 전환** (한 번에 100% 전환 금지)
- **모니터링 대시보드** 사전 구축 (Phase 4에서 필수)

이 문서는 v2/envs/dev/main.tf, 각 Dockerfile, GitHub Actions workflow와 함께 참고하여 실행한다.
