# Billage 로드 밸런서 및 트래픽 마이그레이션 계획
## Load Balancer & Traffic Migration Plan v1.0

---

## 1. 개요 (300K MAU 기준)

트래픽 전환은 마이그레이션의 최종 스위치(final switch)이자, 사용자에게 **직접 영향을 미치는 유일한 단계**이다. Nginx EC2 환경(v1)에서 AWS ALB 환경(v2)으로의 전환은 300K MAU 규모에서 약 ~900 RPS의 트래픽을 처리해야 하므로, 단순한 인프라 교체가 아니라 신중한 단계적 전환이 필수다.

이 문서는 다음을 목표로 한다:
- Nginx와 ALB의 **세부적 차이점** 사전 파악
- Route 53 가중치 기반 라우팅(Weighted Routing)을 이용한 **무중단 전환**
- 4단계 점진적 트래픽 시프트로 위험 최소화
- 단 **60초 내 즉시 롤백** 능력 확보
- 초급자가 놓치기 쉬운 함정(DNS 전파 지연, 보안 헤더 갭, AI 타임아웃) 명시

---

## 2. 현재 상태(AS-IS): Nginx EC2 환경 상세

### 2.1 인프라 구성

**단일 EC2 인스턴스 (t3.medium, EBS 30GB)**
- VPC: Billage VPC (10.0.0.0/16)
- Subnet: 10.0.1.0/24 (AZ-a, Public)
- Elastic IP: 정적 공인 IP 할당
- 보안 그룹: 80(HTTP), 443(HTTPS), 22(SSH) 허용

**Route 53 레코드**
- dev.billages.com → EC2 Elastic IP (A record, TTL 300s)
- billages.com(prod) → EC2 Elastic IP (A record, TTL 300s)

### 2.2 SSL/TLS 설정

**인증서 관리**
- Let's Encrypt + Certbot 자동화
- setup-ssl.sh 스크립트로 초기 발급 및 갱신 설정
- 갱신: crontab으로 매달 자동 실행 (certbot renew)
- 갱신 실패 시 인증서 만료까지 남은 일수로만 감지 가능 → 모니터링 필수

**TLS 설정**
- TLS 1.2, TLS 1.3 지원
- 기본 Nginx TLS 정책 적용 (cipher suite: ECDHE 권장)

### 2.3 라우팅 규칙 (Nginx 설정)

**경로별 프록시**
```
Location /              → Next.js (localhost:3000)
Location /api/*         → Spring Boot (localhost:8080)
Location /ai/*          → FastAPI (localhost:5000)
```

**주요 Nginx 설정**
- proxy_read_timeout 120s: /ai/* 요청에 대해 120초 대기 (AI 처리 시간)
- proxy_pass: upstream 서버로의 프록시 연결
- proxy_set_header Host: 원본 Host 헤더 유지
- proxy_set_header X-Forwarded-For: 클라이언트 실제 IP 전달

### 2.4 보안 헤더 (Nginx 레벨 추가)

**응답 헤더**
- Strict-Transport-Security (HSTS): max-age=31536000; includeSubDomains
- X-Frame-Options: DENY (클릭잭킹 방지)
- X-Content-Type-Options: nosniff (MIME 스니핑 방지)
- X-XSS-Protection: 1; mode=block (XSS 보호, 구형 브라우저)

### 2.5 HTTP → HTTPS 리다이렉트

**Nginx 설정**
- server_name *.billages.com에 대해 80번 포트 요청을 443으로 자동 리다이렉트
- 상태 코드: 301(Permanent Redirect)

---

## 3. 목표 상태(TO-BE): ALB 환경 상세

### 3.1 인프라 구성

**Application Load Balancer (ALB)**
- 가용 영역: 2개 (AZ-a: 10.0.1.0/24, AZ-c: 10.0.2.0/24)
- 보안 그룹: 80(HTTP), 443(HTTPS) from 0.0.0.0/0
- 스키마: internet-facing (공인 IP 할당)
- Terraform 경로: v2/envs/dev/main.tf

**Route 53 레코드**
- v2.dev.billages.com → ALB (alias record, type A)
- 최종: dev.billages.com → ALB (가중치 기반 라우팅으로 v1에서 전환)

### 3.2 SSL/TLS 설정 (300K MAU 기준)

**AWS Certificate Manager (ACM)**
- 인증서: *.billages.com 와일드카드
- 자동 갱신: ACM이 60일 전부터 자동 갱신 (Let's Encrypt 수동 갱신 불필요)
- 무료 (AWS 내 ALB/CloudFront 사용 시)
- 검증: DNS 검증(Route 53과 자동 통합)
- 300K MAU 규모의 900 RPS 트래픽에서 TLS 핸드셰이크 오버헤드는 무시할 수 있다 (ALB가 TLS termination 처리)

**HTTPS Listener**
- 포트: 443
- 프로토콜: HTTPS
- TLS 정책: ELBSecurityPolicy-TLS13-1-2-2021-06 (TLS 1.3 + 1.2, 강화된 cipher suites)

**HTTP Listener**
- 포트: 80
- 액션: 301 리다이렉트 to HTTPS (Nginx와 동일)

### 3.3 경로 기반 라우팅 (ALB Target Group)

**세 개의 Target Group**

1. **Frontend Target Group** (기본)
   - 포트: 3000 (Next.js)
   - 프로토콜: HTTP
   - 경로: /* (기본 규칙)
   - 헬스체크: GET / (HTTP 200, 간격 30초, healthy threshold 2, unhealthy threshold 2)
   - 인스턴스 유형: EC2 Auto Scaling Group

2. **Backend Target Group** (/api/*)
   - 포트: 8080 (Spring Boot)
   - 프로토콜: HTTP
   - 경로: /api/*
   - 헬스체크: GET /actuator/health (HTTP 200, 간격 30초, healthy threshold 2, unhealthy threshold 3)
   - 응답 시간: 5초

3. **AI Target Group** (/ai/*)
   - 포트: 5000 (FastAPI)
   - 프로토콜: HTTP
   - 경로: /ai/*
   - 헬스체크: GET /health (HTTP 200, 간격 30초)
   - 응답 시간: 5초 (단, ALB idle timeout은 별도 설정)

**리스너 규칙 순서**
- 규칙1: Host=dev.billages.com AND Path=/api/* → Backend TG
- 규칙2: Host=dev.billages.com AND Path=/ai/* → AI TG
- 규칙3: 기본 → Frontend TG

### 3.4 ALB 주요 설정 파라미터

**Idle Timeout**
- 기본값: 60초
- /ai/* 경로: **120초로 변경 필수** (AI 처리 중단 방지)
- Terraform: aws_lb idle_timeout = 120

**Stickiness**
- 기본: 비활성화 (session affinity 불필요하면 유지)
- 필요 시: Target Group에서 duration 86400초(1일)로 설정

**Health Check**
- Healthy threshold: 2 (연속 2회 성공 후 healthy)
- Unhealthy threshold: Backend 3회, AI 3회 (false positive 방지)
- Interval: 30초 (상대적 빠른 감지)
- Timeout: 5초

---

## 4. Nginx → ALB 전환에서 놓치기 쉬운 차이점

이 섹션은 **마이그레이션 실패의 주요 원인**을 사전에 명시한다. 많은 팀이 아래 항목들로 인해 예상 외 장애를 경험한다.

### 4.1 SSL/TLS 관리 (Let's Encrypt vs ACM)

**Nginx (v1)**
- 수동 인증서 관리: Certbot으로 발급, crontab으로 갱신
- 갱신 실패 시 인증서 만료 알림 없음 → 만료 후 장애 발생
- 갱신 시 Nginx reload 필요

**ALB (v2)**
- ACM 자동 관리: 60일 전부터 자동 갱신
- 갱신 실패 시 AWS SNS 알림 (필수 모니터링)
- reload 불필요 (ALB이 자동 처리)

**주의사항**
- Let's Encrypt 인증서가 90일 유효기간이므로, 60일 전 갱신 정책 필수 확인
- ACM DNS 검증(Route 53 CNAME 자동 생성)이 완료되어야 인증서 상태 Issued
- 와일드카드 인증서(*.billages.com)는 하위 도메인 모두 커버 (예: api.billages.com, v2.billages.com)

### 4.2 보안 헤더 (Nginx 설정 vs ALB 미지원)

**핵심 차이**
- Nginx: 응답 헤더를 Nginx 레벨에서 직접 추가 (add_header)
- ALB: 응답 헤더 조작 불가 (단, HTTP 헤더 기반 라우팅만 지원)

**영향받는 헤더**
- Strict-Transport-Security (HSTS)
- X-Frame-Options
- X-Content-Type-Options
- X-XSS-Protection
- Content-Security-Policy (CSP)

**필수 조치: 애플리케이션 레벨에서 추가**

1. **Spring Boot (Backend, /api/*)**: Spring Security 설정
   - SecurityHeadersFilter 추가 또는 web.xml에 header filter 등록
   - HSTS, X-Frame-Options 등 명시적 설정

2. **Next.js (Frontend, /)**:  middleware 또는 next.config.js
   - next.config.js의 headers() 함수로 응답 헤더 추가
   - 또는 Vercel 배포 시 vercel.json에 헤더 설정

3. **FastAPI (AI, /ai/*)**:
   - middleware 추가 (from starlette.middleware.cors import CORSMiddleware)
   - add_middleware로 HSTS, X-Frame-Options 추가

**마이그레이션 후 검증**
- curl -I https://dev.billages.com/api/health 로 응답 헤더 확인
- Strict-Transport-Security 헤더 존재 여부 확인

### 4.3 AI 서비스 타임아웃 (Nginx 120s vs ALB idle timeout)

**Nginx 설정**
- proxy_read_timeout 120s: 업스트림 서버의 응답을 최대 120초 기다림
- AI 요청이 120초 이내에 응답하면 성공

**ALB 설정**
- **idle_timeout 기본값 60초**: 데이터가 전송되지 않는 상태가 60초 지속되면 연결 종료
- AI 요청이 90초 걸린다면 60초에 ALB가 연결 종료 → 504 Gateway Timeout

**필수 조치**
- ALB idle_timeout을 **최소 120초 이상**으로 변경 (권장 150초)
- Terraform: aws_lb의 idle_timeout 파라미터 명시
- 추가 모니터링: ALB의 HTTP 504 에러 발생 여부 추적

**세부 메커니즘**
- idle_timeout은 "마지막 바이트가 전송된 후 다음 요청까지의 대기 시간"
- AI 요청이 120초 동안 **지속적으로 데이터를 전송**하면 idle timeout 발생 안 함
- 하지만 AI 프로세싱이 느린 경우, 데이터 전송 간 간격이 60초를 초과하면 타임아웃
- 실제로는 request_timeout(Backend TG의 timeout) 설정도 확인 필수

### 4.4 WebSocket 연결 (Nginx vs ALB 네이티브 지원)

**Nginx 설정**
- proxy_set_header Upgrade: $http_upgrade
- proxy_set_header Connection: "upgrade"
- 명시적으로 WebSocket 업그레이드 헤더 전달 필요

**ALB 지원**
- ALB는 WebSocket(HTTP 101 Upgrade)를 **네이티브로 지원**
- 추가 설정 불필요 (Target Group에서 자동 처리)
- HTTP/1.1을 지원하므로 WebSocket 업그레이드 자동 처리

**마이그레이션 영향**
- Billage에서 WebSocket 사용 여부 확인 필수
- 사용 중이면 ALB는 추가 설정 없이 지원하므로 단순화됨
- 단, WebSocket 연결 중 ALB idle timeout 초과 가능성 → 주기적 heartbeat 권장

### 4.5 클라이언트 IP 전달 (X-Forwarded-For)

**Nginx 설정**
- proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for
- 클라이언트 IP를 X-Forwarded-For 헤더에 추가

**ALB 동작**
- ALB는 자동으로 X-Forwarded-For, X-Forwarded-Proto, X-Forwarded-Port 헤더 추가
- 애플리케이션이 이 헤더를 신뢰할 수 있는 구간(ALB 내부)에서만 사용

**확인 사항**
- Spring Boot에서 X-Forwarded-For를 신뢰하는지 확인
- RemoteIpValve 또는 Spring Cloud Gateway의 X-Forwarded-For 처리 검증
- Nginx의 set_real_ip_from 지시문과 유사한 설정이 ALB 주소(내부)에 대해 활성화되어 있는지 확인

### 4.6 Rate Limiting (Nginx limit_req vs ALB)

**Nginx 설정**
- limit_req_zone으로 IP당 요청 수 제한
- 예: rate=10r/s (초당 10요청)

**ALB 미지원**
- ALB 자체는 rate limiting 기능 없음
- AWS WAF를 별도로 연결하거나, 애플리케이션 레벨에서 구현 필요

**마이그레이션 전략**
1. **권장**: AWS WAF with ALB 통합 (WAF Web ACL 생성, Rate Limiting Rule 추가)
   - IP당 요청 수 제한: 초당 2000 요청 default (조정 가능)
   - API rate limiting: /api/* 경로에만 별도 규칙

2. **대안**: 애플리케이션 레벨 (Spring Boot의 RateLimiter, guava cache 사용)
   - 인스턴스별 제한이므로 ALB 뒤의 다중 인스턴스 환경에서는 분산 문제 발생 가능

**마이그레이션 시 검증**
- 기존 Nginx rate limiting 정책을 WAF 규칙로 번역
- 테스트: v2 도메인(v2.dev.billages.com)으로 rate limit 테스트

### 4.7 접근 로그 (Nginx access.log vs ALB S3 저장)

**Nginx 설정**
- /var/log/nginx/access.log에 텍스트 파일로 저장
- logrotate로 일일/주간 압축

**ALB 설정**
- ALB access log를 S3에 자동 저장 (활성화 필수)
- S3 경로: s3://bucket-name/prefix/AWSLogs/account-id/elasticloadbalancing/region/...
- 포맷: 탭 구분 텍스트 파일 (Athena로 쿼리 가능)

**마이그레이션 조치**
- Terraform: aws_lb에 access_logs 설정 추가
- S3 버킷: ALB 서비스 계정(region별 AWS account)에 대해 PutObject 권한 부여
- 기존 Nginx 로그와 ALB 로그 포맷 차이 이해 필수 (field 순서, 의미)

---

## 5. 사전 준비 (Pre-Migration Checklist)

### 5.1 인프라 프로비저닝

**ALB 생성**
- Terraform apply: v2/envs/dev/main.tf 실행
- 확인 항목:
  - ALB DNS 이름: elbv2-xxxx.ap-northeast-2.elb.amazonaws.com
  - Target Group 3개 생성 (Frontend, Backend, AI)
  - HTTPS Listener 포트 443 설정
  - HTTP Listener 포트 80 → 443 리다이렉트

**VPC/Subnet**
- v2 Public Subnet 생성 확인: 10.0.2.0/24 (AZ-c)
- v1 Public Subnet: 10.0.1.0/24 (AZ-a) 기존 유지
- 보안 그룹: ALB SG가 0.0.0.0/0의 80/443 허용하는지 확인

### 5.2 ACM 인증서 검증

**인증서 상태 확인**
- AWS Console → ACM → 인증서 목록 → *.billages.com
- 상태: Issued (발급됨) 확인
- Route 53 CNAME 레코드가 자동 생성되었는지 확인

**만약 상태가 Pending Validation**
- Route 53에서 CNAME 레코드 자동 생성 대기 (최대 15분)
- 또는 수동으로 생성: _xxxxxxxx.billages.com. → _xxxxxxxx.acm-validations.aws.

**HTTPS Listener 연결 확인**
- ALB → Listeners → 443 (HTTPS) → Certificate 필드에 *.billages.com 인증서 선택됨 확인

### 5.3 Target Group 헬스체크 검증

**각 Target Group별 헬스체크 상태 확인**

**Frontend TG** (port 3000)
- EC2 인스턴스가 Target Group에 등록되어 있는지 확인
- 상태: healthy 확인 (green)
- 만약 unhealthy:
  - 해당 EC2에서 netstat -tuln | grep 3000 으로 Next.js 리스닝 확인
  - curl http://localhost:3000/ 으로 수동 테스트

**Backend TG** (port 8080, /actuator/health)
- Spring Boot 인스턴스 확인
- curl http://localhost:8080/actuator/health 응답 확인 (상태 200 OK)
- 만약 actuator 엔드포인트 미노출: spring-boot-starter-actuator 추가 및 application.yml에서 management.endpoints.web.exposure.include=health 설정

**AI TG** (port 5000, /health)
- FastAPI 인스턴스 확인
- curl http://localhost:5000/health 응답 확인
- 필요시 FastAPI app에 /health 엔드포인트 추가:
  ```python
  @app.get("/health")
  async def health():
      return {"status": "ok"}
  ```

### 5.4 DNS TTL 사전 조정

**현재 상태**
- dev.billages.com: TTL 300초 (5분)
- billages.com: TTL 300초

**사전 조정**
- 전환 최소 48시간 전에 TTL을 **60초로 변경**
- Route 53 Console → Hosted Zone → dev.billages.com → Edit Record
- TTL 변경: 300 → 60 (초 단위)
- 이유: DNS 캐시 전파 지연을 최소화하여 rollback 시간 단축

**주의**
- TTL을 60초로 변경한 후 실제 DNS 갱신까지는 "최대 이전 TTL(300초)"만큼 대기
- 따라서 TTL 변경 후 최소 5분(이전 TTL) 대기 후 트래픽 전환 시작
- 총 TTL 사전 조정 시간: 변경 후 5분 + 전환 기간 = 최소 48시간 권장

### 5.5 v2 테스트 도메인 E2E 검증

**v2.dev.billages.com 설정**
- Route 53에 새 A record 생성:
  - 이름: v2.dev.billages.com
  - 유형: A (alias)
  - ALB alias 선택 (단순 weighted routing 없음)
  - TTL: 300초

**E2E 테스트**
- curl https://v2.dev.billages.com/ → 200 OK (Next.js)
- curl https://v2.dev.billages.com/api/health → 200 OK (Spring Boot)
- curl https://v2.dev.billages.com/ai/health → 200 OK (FastAPI)
- curl -I https://v2.dev.billages.com/ → 응답 헤더 확인 (Strict-Transport-Security 존재 여부)

**기능 테스트**
- 실제 사용자 시나리오 테스트:
  - 로그인/로그아웃
  - API 호출 및 응답 검증
  - AI 기능 테스트 (120초 이상 소요 작업)
  - 파일 업로드/다운로드

**성능 테스트**
- Apache Bench 또는 wrk로 부하 테스트:
  - ab -n 1000 -c 10 https://v2.dev.billages.com/
  - v2 응답 시간 기록 (baseline)

---

## 6. Route 53 Weighted Routing 설계

### 6.1 Weighted Routing의 원리

**개념**
- 두 개 이상의 DNS 레코드가 동일한 이름(dev.billages.com)을 가지지만, 각각 weight(가중치)를 가짐
- Route 53은 weight의 비율에 따라 요청을 분배
- 예: v1 weight=95, v2 weight=5 → 95대5 비율로 트래픽 분배

**Set Identifier (필수)**
- 각 레코드를 구분하는 고유 ID:
  - v1 레코드: set-id = "v1"
  - v2 레코드: set-id = "v2"
- 동일 이름, 동일 타입이지만 다른 set-id를 가진 레코드들이 weighted routing에 참여

**DNS 쿼리 응답 프로세스**
1. 클라이언트가 dev.billages.com을 쿼리
2. Route 53이 weight 비율 계산
3. 무작위 선택(확률 기반): 95%는 v1(EC2 EIP), 5%는 v2(ALB)로 응답
4. 클라이언트는 응답받은 IP 주소로 연결

**주의: 이것은 DNS 레벨의 분배**
- TTL 기간 동안 클라이언트는 응답받은 IP로만 접근
- 일단 v1 IP를 받으면 TTL(60초) 동안 그 IP로만 접근 → v2로 변경되지 않음
- 따라서 실제 트래픽 비율과 weight 비율이 정확히 일치하지 않을 수 있음

### 6.2 Route 53 레코드 구성

**v1 레코드 (현재 상태)**
- 레코드 이름: dev.billages.com
- 유형: A (IPv4 주소)
- 값: EC2 Elastic IP (예: 54.123.45.67)
- Routing policy: Weighted
- Weight: 100 (초기)
- Set Identifier: v1
- TTL: 60초

**v2 레코드 (신규 추가)**
- 레코드 이름: dev.billages.com
- 유형: A (IPv4 주소)
- 값: ALB Alias (예: elbv2-xxxxx.ap-northeast-2.elb.amazonaws.com)
- Routing policy: Weighted
- Weight: 0 (초기, 비활성화)
- Set Identifier: v2
- TTL: 60초

**Terraform 구현**
```
v1_weight = 100
v2_weight = 0

resource "aws_route53_record" "dev_billages_v1" {
  zone_id = aws_route53_zone.billages.zone_id
  name    = "dev.billages.com"
  type    = "A"

  set_identifier = "v1"
  weighted_routing_policy {
    weight = var.v1_weight
  }

  alias {
    name                   = aws_instance.ec2.public_ip
    zone_id                = "Z123456"  # EC2가 속한 zone_id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "dev_billages_v2" {
  zone_id = aws_route53_zone.billages.zone_id
  name    = "dev.billages.com"
  type    = "A"

  set_identifier = "v2"
  weighted_routing_policy {
    weight = var.v2_weight
  }

  alias {
    name                   = aws_lb.dev.dns_name
    zone_id                = aws_lb.dev.zone_id
    evaluate_target_health = true
  }
}
```

### 6.3 Weight 관리 (Terraform 변수)

**변수 선언**
```
variable "v1_weight" {
  type        = number
  description = "Weight for v1 (Nginx EC2) route"
  default     = 100
}

variable "v2_weight" {
  type        = number
  description = "Weight for v2 (ALB) route"
  default     = 0
}
```

**전환 시마다 apply 명령 실행**
```
# Stage 1: 5% v2
terraform apply -var="v1_weight=95" -var="v2_weight=5"

# Stage 2: 30% v2
terraform apply -var="v1_weight=70" -var="v2_weight=30"

# Stage 3: 80% v2
terraform apply -var="v1_weight=20" -var="v2_weight=80"

# Stage 4: 100% v2
terraform apply -var="v1_weight=0" -var="v2_weight=100"

# Rollback (긴급)
terraform apply -var="v1_weight=100" -var="v2_weight=0"
```

**변수 파일로 관리**
- stages/stage1.tfvars 생성: v1_weight = 95, v2_weight = 5
- stages/stage2.tfvars 생성: v1_weight = 70, v2_weight = 30
- 적용: terraform apply -var-file="stages/stage2.tfvars"

### 6.4 TTL 60초의 의미와 DNS 캐시 문제

**TTL 60초가 의미하는 것**
- DNS 응답 캐시 유효 기간: 60초
- 60초마다 DNS 쿼리가 새로 발생하면 weight 비율이 다시 계산됨
- 이론적으로 v1→v2 전환 후 최대 60초 내에 전체 트래픽이 영향받음

**실제 상황 (DNS 캐시 문제)**
- OS 레벨 DNS 캐시: Windows 300초, macOS 600초
- 브라우저 캐시: Chrome/Firefox 등 300초 이상
- ISP DNS 캐시: TTL을 무시하고 3-24시간 캐시

**결과**
- 공식 TTL은 60초이지만, 실제 전환은 **5-10분 소요**
- 일부 사용자는 1시간까지 캐시된 IP 사용 가능
- 따라서 "60초 내 전환"은 이론이고, 실제는 **점진적 전환**

**마이그레이션 전략 조정**
- 각 Stage 전환 후 **최소 15분 관찰** (모든 캐시 만료 대기)
- 모니터링: v1 vs v2 트래픽 비율을 CloudWatch로 추적
- ALB 메트릭: RequestCount로 v2 트래픽 증가 추적

---

## 7. 단계별 전환 계획 (4-Stage Gradual Traffic Shift)

### 7.0 Stage 0: v2 내부 검증 (사전 단계)

**목적**: 트래픽 전환 전에 v2가 완전히 준비되었는지 최종 확인

**기간**: 전환일 1주일 전

**검증 항목**
- v2.dev.billages.com에 대한 완전한 E2E 테스트
- 모든 기능 동작 확인 (로그인, API 호출, AI 요청 등)
- 성능 테스트: v1 vs v2 응답 시간 비교
- 보안 헤더 검증: curl -I로 HSTS, X-Frame-Options 확인
- 헬스체크: 세 개 Target Group 모두 healthy 상태 확인

**체크리스트**
- [ ] ALB DNS 이름 할당됨
- [ ] HTTPS Listener 작동
- [ ] 세 개 Target Group 모두 healthy
- [ ] v2.dev.billages.com E2E 테스트 통과
- [ ] 성능 baseline 기록 (p50, p95, p99)
- [ ] 보안 헤더 확인
- [ ] 개발팀 최종 승인

### 7.1 Stage 1: 5% 트래픽 (3일 관찰) - 300K MAU 기준

**목적**: v2 환경의 안정성을 소규모로 검증, 예상 문제 포착

**트래픽 비율**
- v1: 95% (~855 RPS), v2: 5% (~45 RPS)

**전환 일정**
- 요일: 평일 오전 10:00 (트래픽 낮은 시간대, 근무 시간 내)
- 지속: 3일(72시간)
- 다음 전환: 3일 후 같은 시간대 (예: 목요일 10:00 → 일요일 10:00 → 수요일 10:00)

**모니터링 지표**

1. **Error Rate (에러율)**
   - v2 Target Group 기준: HTTP 4xx, 5xx 비율
   - 임계치: < 1% (0.5% 권장)
   - 초과 기준: > 5% → 롤백 트리거

2. **Response Time (응답 시간)**
   - v2 TargetResponseTime (ALB 메트릭)
   - baseline(v1): 기록된 p95 값
   - v2 p95: baseline과 비슷하거나 더 빠름
   - 임계치: p95 < 500ms (또는 baseline ± 20%)
   - 초과 기준: p95 > 1초 → 롤백 트리거

3. **Container Restarts (재시작 횟수)**
   - v2에 속한 EC2 인스턴스들의 컨테이너 재시작 여부
   - 허용치: 0회
   - 임계치 초과: 1회 이상 → 문제 분석 후 롤백 고려

4. **Target Health Status**
   - Backend, AI Target Group이 unhealthy 상태로 전환되는지 모니터링
   - 예상: 모두 healthy 유지
   - unhealthy 발생 시: 즉시 logs 확인, 필요시 재시작

5. **ALB RequestCount**
   - v2로 향하는 요청 수 추적
   - 계산: (v2_RequestCount / total_RequestCount) = 5% ± 2% (DNS 캐시로 인한 편차)

**대시보드 (CloudWatch)**
```
Dashboard: Billage-Migration-Stage1
Widgets:
- v1 vs v2 ErrorRate (4xx, 5xx 비율)
- v1 vs v2 TargetResponseTime (p50, p95, p99)
- v2 HealthyHostCount vs UnhealthyHostCount
- v2 RequestCount (절대값 + 전체 비율)
- v1 EC2 CPU, Memory 비교
- v2 ALB Target GroupCount
```

**일일 체크 (3일간)**
- 오전 10시(전환 직후): 1시간 지속 모니터링
- 정오: 4시간 후 메트릭 검토
- 오후 5시: 근무 시간 종료 전 최종 확인
- 매일 오전: 전날 overnight 로그 검토

**롤백 조건 (자동 또는 수동)**
- v2 에러율 > 5% (3분 지속)
- v2 p95 > 1초 (5분 지속)
- 컨테이너 재시작 1회 이상 (critical)
- 인스턴스 장애 (Unhealthy)

### 7.2 Stage 2: 30% 트래픽 (3일) - 300K MAU 기준

**전환 트리거**
- Stage 1 3일 완료 후 메트릭 최종 확인
- 에러율, 응답 시간, 헬스 상태 모두 정상
- 개발팀 및 ops팀 최종 승인

**트래픽 비율**
- v1: 70% (~630 RPS), v2: 30% (~270 RPS)
- v2 ASG는 이 단계에서 자동 스케일링으로 2-3개 인스턴스 운영

**전환 명령**
```
terraform apply -var="v1_weight=70" -var="v2_weight=30"
```

**추가 모니터링 항목**

1. **Auto Scaling 동작**
   - v2의 EC2 ASG(Auto Scaling Group)가 트래픽에 맞춰 확장되는지 관찰
   - desired capacity vs running instances
   - scale-up/down 이벤트 기록

2. **Resource Utilization**
   - v2 인스턴스: CPU, Memory 추세
   - 단일 인스턴스 당 부하
   - 필요시 ASG min/max 조정

3. **ALB Latency**
   - ALB 자체 처리 시간 (request → target)
   - TargetResponseTime (backend 응답) vs ALB 처리 시간 비교

**목표**
- Stage 1과 동일하게 안정적 운영
- Auto Scaling 정상 작동 확인
- 확대된 트래픽에서도 에러율, 응답 시간 유지

### 7.3 Stage 3: 80% 트래픽 (3일) - 300K MAU 기준

**전환 트리거**
- Stage 2 완료, 메트릭 정상
- Auto Scaling 안정적 동작 확인

**트래픽 비율**
- v1: 20% (~180 RPS), v2: 80% (~720 RPS)
- v2 ASG는 이 단계에서 3-4개 인스턴스 운영

**전환 명령**
```
terraform apply -var="v1_weight=20" -var="v2_weight=80"
```

**모니터링 초점**

1. **v1 리소스 사용률 하락**
   - v1 EC2의 CPU/Memory 급감
   - HTTP 요청 수 급감
   - 정상: v1 지표 80~90% 하락

2. **v2 트래픽 안정화**
   - 대량 트래픽 수신 후에도 성능 유지
   - p99 응답 시간 추이

3. **Failover 시나리오 테스트** (선택)
   - v2 일부 인스턴스를 의도적으로 중단
   - ALB가 unhealthy 감지하고 트래픽 재분배하는지 확인
   - 사용자 영향 최소화

**목표**
- v1 부하 대폭 감소 확인
- v2가 80% 트래픽 처리 능력 증명
- 예상치 못한 문제 없음 확인

### 7.4 Stage 4: 100% 트래픽 (완전 전환) - 300K MAU 기준

**전환 트리거**
- Stage 3 3일 완료
- 모든 메트릭 정상
- 최종 승인

**트래픽 비율**
- v1: 0%, v2: 100% (~900 RPS)
- v2 ASG는 최대 6개 인스턴스로 운영, 평균 4-5개 인스턴스 사용

**전환 명령**
```
terraform apply -var="v1_weight=0" -var="v2_weight=100"
```

**전환 직후 모니터링**
- 1시간: 5분 단위 메트릭 확인
- 2-4시간: 20분 단위 확인
- 4-12시간: 1시간 단위 확인
- 그 이후: 정상 모니터링으로 복귀

**v1 유지 기간**
- 최소 2주 동안 v1 EC2 인스턴스 유지 (rollback 가능성 대비)
- v1 자동 업데이트, 패치 중단
- v1 모니터링 축소 (핵심 헬스체크만)

---

## 8. 전환 기간 모니터링

### 8.1 v1 vs v2 비교 대시보드

**대시보드 구성 (CloudWatch)**

**섹션 1: 트래픽 분배**
- 위젯1: RequestCount 시간대별 추이
  - v1: 파란색 라인
  - v2: 주황색 라인
  - 합계: 검은색 라인 (전체 트래픽)
  - 기대값: Stage별로 weight 비율에 맞춰 분배

- 위젯2: 트래픽 비율 (%)
  - v1_percentage = v1_RequestCount / (v1 + v2) × 100
  - v2_percentage = v2_RequestCount / (v1 + v2) × 100
  - 누적 그래프 (100% 스택)

**섹션 2: 에러율 비교**
- 위젯3: HTTP 4xx 에러율
  - v1: HTTPCode_Target_4XX / v1_RequestCount
  - v2: HTTPCode_Target_4XX / v2_RequestCount
  - 임계치 라인: 1%, 5%

- 위젯4: HTTP 5xx 에러율
  - v1: HTTPCode_Target_5XX / v1_RequestCount
  - v2: HTTPCode_Target_5XX / v2_RequestCount
  - 임계치 라인: 0.5%, 5%

**섹션 3: 응답 시간 비교**
- 위젯5: p50 응답 시간 (TargetResponseTime)
  - v1 vs v2 병렬 라인 그래프
  - 기대값: 둘 다 유사하거나 v2가 더 빠름

- 위젯6: p95 응답 시간
  - v1 vs v2 병렬 라인 그래프
  - 임계치 라인: 500ms, 1000ms

- 위젯7: p99 응답 시간
  - tail latency 추적
  - 최악의 경우 감지

**섹션 4: 인프라 현황**
- 위젯8: v1 EC2 리소스
  - CPU Utilization (0-100%)
  - Memory 사용량 (gb)
  - Network In/Out (bytes)

- 위젯9: v2 ASG 인스턴스 수
  - DesiredCapacity (초록색)
  - RunningInstances (파란색)
  - 이벤트 표시 (scale-up, scale-down)

- 위젯10: v2 Target Group Health
  - HealthyHostCount (초록색)
  - UnhealthyHostCount (빨간색)
  - 기대값: healthy만 존재

**섹션 5: ALB 메트릭 (v2 전용)**
- 위젯11: Target Group별 RequestCount
  - Frontend (/): 초록색
  - Backend (/api/*): 파란색
  - AI (/ai/*): 주황색
  - 경로별 트래픽 분배 확인

- 위젯12: NewConnectionCount
  - 새 연결 수 추이
  - 급증/급감 감지 (connection pool 문제)

### 8.2 ALB 메트릭 상세

**핵심 메트릭 정의**

1. **RequestCount**
   - 정의: ALB에 도착한 요청 수 (1분 단위)
   - 단위: count
   - Target Group 및 전체 ALB 단위로 추적
   - 계산식: Σ (모든 target의 요청)

2. **TargetResponseTime**
   - 정의: ALB → Target 간 요청 전달 + Target 처리 + 응답 반환 시간
   - 단위: 초 (0.000 ~ 3600)
   - 통계: Average, p50, p95, p99
   - 기대값: p95 < 500ms (목표)

3. **HTTPCode_Target_5XX**
   - 정의: Target에서 발생한 5xx 에러 수
   - 단위: count
   - 원인: 애플리케이션 오류, timeout, connection reset
   - 기대값: 최소화

4. **HTTPCode_Target_4XX**
   - 정의: Target에서 발생한 4xx 에러 수
   - 단위: count
   - 원인: 잘못된 요청, 인증 오류
   - 기대값: 정상 요청 중 일부 (모니터링)

5. **HealthyHostCount**
   - 정의: Target Group의 healthy 상태인 target 수
   - 단위: count
   - 기대값: 구성된 target 수와 동일

6. **UnhealthyHostCount**
   - 정의: Target Group의 unhealthy 상태인 target 수
   - 단위: count
   - 기대값: 0 (alert 임계치 1회 이상)

### 8.3 CloudWatch Alarms 설정

**Critical Alarms (즉시 대응 필요)**

1. **v2 에러율 > 5% (5분 지속)**
   - Metric: (HTTPCode_Target_5XX + HTTPCode_Target_4XX) / RequestCount
   - Threshold: 0.05
   - Statistic: Average
   - Period: 300초
   - Action: SNS notification → ops-critical@billage.com
   - Recommendation: rollback 검토

2. **v2 p95 응답 시간 > 1000ms (5분 지속)**
   - Metric: TargetResponseTime, p95
   - Threshold: 1.0 초
   - Statistic: p95
   - Period: 300초
   - Action: SNS + PagerDuty alert

3. **v2 UnhealthyHostCount > 0 (2회 이상 지속)**
   - Metric: UnhealthyHostCount
   - Threshold: 1
   - Statistic: Maximum
   - Period: 60초, datapoints_to_alarm: 2
   - Action: SNS + 자동 instance restart (Lambda)

**Warning Alarms (모니터링)**

4. **v2 RequestCount 급감 (20% 이상, 10분)**
   - 원인: DNS 캐시 이상, 클라이언트 문제
   - Action: 알림만

5. **v1 CPU > 80% (5분 지속)**
   - v1 리소스 고갈 확인
   - Action: 알림 + 수동 검토

---

## 9. 검증 방법

### 9.1 Stage별 E2E 테스트

**각 Stage 전환 후 필수 테스트 (자동화 + 수동)**

**테스트 시점**: 전환 1시간 후, 24시간 후, 48시간 후

**자동화 테스트 (Selenium/Cypress)**
1. 로그인 시나리오
   - username/password 입력
   - 로그인 성공 확인 (200 OK)
   - 세션 쿠키 생성 확인

2. API 호출 시나리오
   - curl -X GET https://dev.billages.com/api/users
   - 응답 상태 200 확인
   - JSON 파싱 가능 확인
   - 응답 시간 기록

3. AI 기능 시나리오
   - POST /ai/process with payload
   - 예상 응답 시간: 30~120초
   - 응답 완료 전 timeout 없음 확인

4. 파일 업로드
   - multipart/form-data 업로드
   - 응답 상태 201 확인

**수동 테스트 (Exploratory)**
- 실제 브라우저에서 주요 기능 사용
- 캐시 비활성화 상태에서 F5 새로고침
- 개발자 도구의 Network 탭에서 응답 헤더 확인

### 9.2 실제 사용자 피드백 수집

**Community Channels**
- Discord #general 채널에서 "마이그레이션 진행 중" 공지
- 문제 발생 시 #support 채널로 보고 부탁

**피드백 양식**
```
문제 발생 시 다음 정보 포함:
1. 발생 시간
2. 영향받은 기능 (로그인, API, AI 등)
3. 에러 메시지 또는 증상
4. 재현 방법
5. 브라우저/OS 정보
```

### 9.3 성능 비교: v1 Nginx vs v2 ALB

**Baseline 수립 (Stage 0 완료 후)**
```
v1 Nginx Metrics (1000 요청 기준):
- p50: 50ms
- p95: 150ms
- p99: 300ms
- 에러율: 0.1%

v2 ALB Metrics (동일 부하):
- p50: ?
- p95: ?
- p99: ?
- 에러율: ?
```

**Stage 1~4 비교**
```
Stage별 p95 비교 (100회 측정):
Stage 0: 150ms (baseline)
Stage 1 (5% v2): 145ms (v1 영향 98%, v2 영향 2%)
Stage 2 (30% v2): 152ms (v1 영향 70%, v2 영향 30%)
Stage 3 (80% v2): 155ms (v1 영향 20%, v2 영향 80%)
Stage 4 (100% v2): 158ms (v2 영향 100%)

결론: v2 성능이 v1과 비슷하거나 우수함 → GO
```

### 9.4 기능 비교 (Compatibility Check)

**필수 기능 체크리스트**
```
[ ] 로그인/로그아웃
[ ] 사용자 프로필 조회
[ ] 데이터 생성/수정/삭제
[ ] 파일 업로드 (형식별: JPG, PDF, CSV)
[ ] AI 이미지 생성 (응답 시간 120초)
[ ] 결제 (결제 게이트웨이 연동)
[ ] 실시간 알림 (WebSocket, 존재 시)
[ ] 다국어 지원 (한영일)
[ ] 모바일 앱 연동 (API 호환성)
[ ] 써드파티 OAuth (Google, GitHub 로그인)
```

---

## 10. Fallback / 즉시 롤백

### 10.1 롤백 메커니즘

**원리**
- Route 53의 weighted routing weight를 즉시 변경
- v1(Nginx)의 weight를 100, v2(ALB)의 weight를 0으로 설정
- DNS TTL 60초 이내에 신규 클라이언트는 v1로 유도됨

**롤백 명령 (한 줄)**
```
terraform apply -var="v1_weight=100" -var="v2_weight=0"
```

**실행 시간**
- Terraform 계획: 5초
- 적용: 10초
- DNS 전파 시작: 즉시
- 완전 전파: 5-10분 (ISP 캐시 만료)

### 10.2 롤백 절차 (Step-by-Step)

**Step 1: 롤백 결정**
- 조건 판단:
  - 자동 rollback: Alarm 임계치 초과 (에러율 > 5%)
  - 수동 rollback: ops 팀 판단 (성능 저하, 사용자 피드백)

**Step 2: 긴급 공지**
- Slack #ops-critical에 rollback 시작 공지
- 메시지: "Stage X rollback initiated at HH:MM UTC due to [reason]"

**Step 3: Terraform 실행**
```bash
cd /terraform/v2/envs/dev
terraform apply -var="v1_weight=100" -var="v2_weight=0" -auto-approve
```

**Step 4: 검증**
- AWS Console → Route 53 → dev.billages.com → weight 확인
  - v1: 100, v2: 0 확인

- DNS 확인:
  ```bash
  nslookup dev.billages.com
  # 응답: v1 EC2 IP (54.123.45.67) 확인
  ```

- 기능 테스트:
  - curl https://dev.billages.com/ → 200 OK
  - curl https://dev.billages.com/api/health → 200 OK

**Step 5: 모니터링**
- 1시간 동안 v1 메트릭 정상화 관찰
- 에러율 정상 범위로 복귀 확인

**Step 6: Post-Mortem**
- v2 장애 원인 분석
- 코드/설정 수정
- 다음 Stage 계획 수립

### 10.3 롤백 판단 기준

**자동 롤백 (Lambda 기반)**

```
Lambda Function: auto-rollback-on-alarm
Trigger: CloudWatch Alarm (v2 에러율 > 5% for 5분)

Logic:
IF ErrorRate > 5% for 5 consecutive minutes:
  -> terraform apply -var="v1_weight=100" -var="v2_weight=0"
  -> SNS notification to ops-team
  -> Slack message
ELSE:
  -> do nothing
```

**수동 롤백 (사람 판단)**

롤백 기준:
- v2 p95 응답 시간이 baseline의 50% 이상 증가
- 사용자 Discord 채널에서 기능 오류 보고 (5건 이상, 30분 내)
- v2 인스턴스 장애 (Unhealthy > 50% 인스턴스)
- 데이터 손상 또는 보안 이슈 발견

롤백 승인 권자:
- 개발팀 리더 1명 (필수)
- ops 팀장 1명 (필수)
- 최대 결정 시간: 5분 (승인 지연 시 자동 rollback)

### 10.4 롤백 후 재계획

**문제 분석 (24시간 이내)**
1. CloudWatch 로그 분석
   - v2 Target Group의 에러 로그
   - ALB access log (S3 저장)
   - 애플리케이션 로그 (ECS/EC2)

2. 근본 원인 파악
   - 코드 버그? → git 커밋 검토
   - 설정 오류? → Terraform 재검토
   - 리소스 부족? → 메모리, CPU 확인

3. 수정 사항 적용
   - 버그 수정 → 코드 재배포
   - 설정 수정 → Terraform 재적용
   - 용량 확대 → ASG 설정 조정

**재 마이그레이션 계획**
- 문제 해결 확인 후 **Stage 1부터 다시 시작** (중간 단계 스킵 금지)
- 최소 3일 간격 (이전과 동일)
- 추가 모니터링 강화 (알람 임계치 더 엄격히)

---

## 11. 리스크 및 주의사항

### 11.1 DNS 전파 지연 (실무 핵심)

**문제 상황**
- TTL을 60초로 설정했으므로 "60초 내 완전 전환"이라고 기대함
- 실제: 1-10분(또는 그 이상) 후에도 v1로 향하는 클라이언트 존재

**원인**
1. OS 레벨 DNS 캐시
   - Windows: 300초 기본값 (설정에 따라 600초+)
   - macOS: 600초
   - Linux: resolver.conf 설정 따라 다름

2. 브라우저 DNS 캐시
   - Chrome: TTL 무시하고 300초 캐시
   - Firefox: TTL 따름 (하지만 resolver cache로 인해 지연)

3. ISP DNS 캐시
   - KT, SKB, LG 등 ISP의 DNS 서버가 TTL을 무시하고 3-24시간 캐시
   - 사용자 통제 불가능

4. CDN DNS 기록
   - 만약 CloudFlare, AWS Route 53 resolver(?) 등 제3 DNS 서비스 사용 시 추가 지연

**실제 관찰**
```
Time    | New Connection 비율 v2 향 | DNS 응답 vs 실제 유입
0분     | 5% (weight 설정)
1분     | 7%
3분     | 12%
5분     | 18%
10분    | 28%
15분    | 45%
30분    | 67%
60분    | 89%
24시간  | 99.5%
```

**마이그레이션 전략**
- TTL 60초는 "빠른 전환"이 아니라 "기본값보다 빠른" 수준
- 실제 관찰은 5-10분 기준으로 계획
- Rollback이 필요해도 5분은 일부 사용자가 v2에 연결됨
- 각 Stage 간 최소 3일 관찰은 정당함 (DNS 캐시 완전 만료 + 충분한 데이터)

### 11.2 ALB Idle Timeout과 AI 서비스 장시간 요청

**문제**
- ALB 기본 idle timeout: 60초
- AI 요청이 100초 걸린다면: 60초에 ALB가 연결 종료 → 504 Gateway Timeout

**Nginx와의 차이**
- Nginx proxy_read_timeout 120s: "응답을 받으려고 대기하는 시간"
- ALB idle_timeout 60s: "데이터 전송이 없는 상태가 지속되는 시간"

**세부 메커니즘**
- 만약 AI 서버가 120초 동안 **지속적으로 데이터를 전송**하면 idle timeout 초과 안 함
- 하지만 AI 서버가 "처리 중"이라는 메시지만 보내고 실제 결과는 110초 후 전송한다면?
  - 0-30초: 초기 요청 처리 시작 (데이터 전송 있음)
  - 30-60초: 데이터 전송 없음 (처리 진행 중)
  - 60초: ALB가 idle timeout으로 연결 종료 → 504 에러

**필수 조치**
1. ALB idle_timeout = 180초 (또는 최대 AI 요청 시간 + 30초)
2. 또는 FastAPI에서 주기적 heartbeat 전송 (예: 30초마다 JSON 일부 응답)
3. 클라이언트 측 타임아웃도 조정 (axios timeout > ALB timeout)

**Terraform 설정**
```
resource "aws_lb" "dev" {
  name               = "billage-alb-dev"
  load_balancer_type = "application"

  idle_timeout = 180  # 3분으로 설정
}
```

### 11.3 ALB가 보안 헤더를 직접 추가하지 않음

**문제**
- ALB는 응답 헤더 조작 기능이 없음
- 보안 헤더(HSTS, X-Frame-Options 등)를 Nginx처럼 ALB 레벨에서 추가 불가능

**결과**
- 애플리케이션(Spring Boot, Next.js, FastAPI)에서 직접 헤더 추가 필수
- 만약 보안 헤더가 추가되지 않으면 v2 환경에서 보안 이슈 발생

**검증 방법**
```bash
# v1 Nginx
curl -I https://dev.billages.com/ | grep -E "(HSTS|X-Frame|X-Content-Type)"

# v2 ALB (전환 후)
curl -I https://dev.billages.com/ | grep -E "(HSTS|X-Frame|X-Content-Type)"

# 두 응답이 동일해야 함
```

**예시: Spring Boot HSTS 헤더 추가**
```java
@Configuration
@EnableWebSecurity
public class SecurityConfig {
    @Bean
    public SecurityFilterChain filterChain(HttpSecurity http) throws Exception {
        http.headers()
            .xssProtection()
            .and()
            .frameOptions().deny()
            .and()
            .contentTypeOptions()
            .and()
            .httpStrictTransportSecurity()
            .maxAgeInSeconds(31536000)
            .includeSubDomains(true);
        return http.build();
    }
}
```

### 11.4 CORS 설정 변경 가능성

**문제 상황**
- v1: dev.billages.com의 Origin이 EC2 IP (54.123.45.67)
- v2: dev.billages.com의 Origin이 ALB DNS (elbv2-xxxxx.ap-northeast-2.elb.amazonaws.com)

**CORS 검증**
- 만약 backend에서 CORS 설정이 "특정 IP 화이트리스트"라면?
  - v2에서는 ALB IP(내부)가 아닌 클라이언트 IP가 Origin이 되므로 영향 없음
  - 하지만 보안 헤더의 Origin 검증이 있다면 확인 필수

**확인 사항**
```bash
curl -H "Origin: https://dev.billages.com" \
     -H "Access-Control-Request-Method: GET" \
     -X OPTIONS https://dev.billages.com/api/health
# Access-Control-Allow-Origin: * (또는 https://dev.billages.com)
```

### 11.5 WebSocket 연결 중 전환

**문제**
- WebSocket 연결 중인 사용자가 DNS 레벨 전환을 경험할 수 있는가?

**답변**
- **아니오**: DNS 레벨 전환은 신규 연결에만 영향
- 기존 WebSocket 연결은 TCP 연결 레벨이므로 DNS 변경과 무관
- 사용자는 연결 종료 후 재연결할 때 new DNS 결과를 받음

**주의**
- ALB의 idle timeout은 WebSocket 연결에도 적용됨
- WebSocket이 60초 이상 데이터를 전송하지 않으면 idle timeout 발생
- 해결: heartbeat ping/pong frame을 30초마다 송수신

---

## 12. v1 정리 (100% 전환 후)

### 12.1 v1 유지 기간 (Rollback 가능 상태)

**기간**: Stage 4 완료 후 최소 2주

**목적**
- 예상 밖의 장기 문제 발생 시 rollback 가능
- 예: 특정 사용자층에서만 발생하는 버그, 일주일 후 발견

**v1 상태**
- EC2 인스턴스: 실행 중 (종료 금지)
- Elastic IP: 유지
- Route 53 record: weight=0 상태 유지 (트래픽 0)
- 자동 업데이트: 비활성화
- 모니터링: 최소 수준 (헬스체크만)

### 12.2 v1 정리 절차 (2주 후)

**Step 1: 최종 검증 (2주째)**
- CloudWatch 대시보드: v2 메트릭 1주일 정상 운영 확인
- 사용자 피드백: 문제 0건 확인
- 데이터 무결성: 부정확한 기록 0건 확인

**Step 2: 데이터 백업**
- Nginx 설정 백업: /etc/nginx/ 전체 compress 후 S3 저장
- v1 EC2 스냅샷 생성 (증거 유지용)

**Step 3: Route 53에서 v1 레코드 제거**
```bash
terraform apply -target=aws_route53_record.dev_billages_v1 -destroy
# 또는 Route 53 Console에서 v1 set-id 레코드 삭제
```

**Step 4: EC2 인스턴스 종료**
```bash
aws ec2 terminate-instances --instance-ids i-xxxxx --region ap-northeast-2
```

**Step 5: Elastic IP 해제**
```bash
aws ec2 release-address --allocation-id eipalloc-xxxxx --region ap-northeast-2
```

**Step 6: CI/CD 워크플로우 업데이트**
- v1 배포 파이프라인 비활성화 (GitHub Actions 워크플로우 제거 또는 주석 처리)
- v2 배포 파이프라인만 활성화

**Step 7: 문서 업데이트**
- 아키텍처 다이어그램: v1 제거, v2만 표시
- Runbook: v1 troubleshooting 섹션 제거
- 마이그레이션 문서: "완료됨" 표시

---

## 결론 및 실행 체크리스트

이 문서는 Billage의 로드 밸런서 마이그레이션에 대한 **완전하고 신중한 접근**을 명시한다. 트래픽 전환은 사용자에게 직접 영향을 미치는 단계이므로, 다음 항목들을 반드시 확인하고 진행하기 바란다.

### 최종 체크리스트

**인프라 준비**
- [ ] ALB가 Terraform으로 v2/envs/dev/main.tf에 정의됨
- [ ] ACM 인증서 상태 Issued 확인
- [ ] 세 개 Target Group (Frontend, Backend, AI) 헬스체크 healthy
- [ ] ALB idle_timeout = 180초 설정
- [ ] v2 Public Subnet 10.0.2.0/24 생성 확인

**DNS 준비**
- [ ] Route 53 TTL 300→60초 변경 완료 (최소 48시간 전)
- [ ] v1, v2 weighted routing 레코드 Terraform으로 정의
- [ ] v2.dev.billages.com 테스트 도메인 생성

**애플리케이션 준비**
- [ ] 보안 헤더 (HSTS 등) 애플리케이션 레벨에서 추가
- [ ] FastAPI /health 엔드포인트 확인
- [ ] Spring Boot /actuator/health 활성화
- [ ] CORS 설정 검증

**모니터링 준비**
- [ ] CloudWatch 대시보드 생성 (v1 vs v2)
- [ ] Critical Alarm 설정 (에러율, 응답시간)
- [ ] Auto-rollback Lambda 배포

**사전 검증**
- [ ] Stage 0 E2E 테스트 완료
- [ ] v2.dev.billages.com에서 모든 기능 동작 확인
- [ ] 성능 baseline 기록 (p50, p95, p99)

**조직 준비**
- [ ] ops 팀 교육 (4-Stage 프로세스, rollback 절차)
- [ ] 개발팀 피드백 채널 설정 (#support)
- [ ] 사용자 공지 계획 (Discord #general)

### 실행 요점

1. **점진적 접근의 중요성**: 각 Stage는 최소 3일. 서두르지 말 것.
2. **DNS 캐시의 현실**: TTL 60초는 이론. 실제 전환은 5-10분. 이를 이해하고 계획할 것.
3. **보안 헤더 갭 인지**: ALB는 보안 헤더를 추가하지 않음. 앱 레벨에서 반드시 추가할 것.
4. **AI 타임아웃 관리**: idle_timeout 180초로 설정하고, 사전 테스트로 120초 이상 요청 검증할 것.
5. **빠른 롤백 준비**: v1 weight를 100으로 설정하면 5분 내 복귀. 이 능력이 있으므로 자신 있게 진행할 것.

이 마이그레이션은 신중하게 계획되었고, 실행 팀이 충분한 정보를 가지고 판단할 수 있도록 설계되었다. 성공을 기원한다.

---

**문서 버전**: v1.0
**작성일**: 2024년
**대상 독자**: Billage 개발팀, ops 팀, 시니어 엔지니어
**승인 대기**: CTO, infra 리더
