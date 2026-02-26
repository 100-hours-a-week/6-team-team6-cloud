# Billage v2 인프라 구축 & 마이그레이션 마일스톤

## 전체 타임라인

```
Phase 1: 기반 구축 ─────────────────── Week 1-2
  ├─ M1: Docker 이미지 & ECR        (3-4일)
  └─ M2: 데이터 계층 (RDS + Redis)   (2-3일)  ← M1과 병렬 가능

Phase 2: 네트워크 & 컴퓨트 ─────────── Week 3-4
  ├─ M3: 네트워크 & ALB              (3-4일)
  └─ M4: Auto Scaling Group          (4-5일)

Phase 3: 파이프라인 & 모니터링 ──────── Week 5
  ├─ M5: CI/CD v2 파이프라인          (2-3일)  ← M6과 병렬 가능
  └─ M6: 모니터링 전환                (2-3일)

Phase 4: 데이터 마이그레이션 ─────────── Week 6
  └─ M7: MySQL → RDS                (3-4일, 리허설 포함)

Phase 5: 트래픽 전환 ──────────────── Week 7-9
  ├─ M8: 점진적 트래픽 전환           (3주, 관찰 포함)
  └─ M9: v1 인프라 정리              (1일 + 2주 관찰)
```

---

## 의존성 맵

```
M1 (ECR) ─────────────────┐
                           │
M2 (RDS + Redis) ────┐    │
                      ▼    ▼
                 M3 (ALB + 네트워크)
                      │
                      ▼
                 M4 (ASG)
                      │
            ┌─────────┼─────────┐
            ▼                   ▼
       M5 (CI/CD)         M6 (모니터링)
            │                   │
            └─────────┬─────────┘
                      ▼
                 M7 (DB 마이그레이션)
                      │
                      ▼
                 M8 (트래픽 전환)
                      │
                      ▼
                 M9 (v1 정리)
```

---

## Phase 1: 기반 구축 (Week 1-2)

---

### M1. Docker 이미지 & ECR 파이프라인

**목표**: 각 서비스 Docker 이미지를 빌드하고 ECR에 push하는 파이프라인 완성
**선행 조건**: 없음
**소요**: 3-4일

#### 태스크

- [ ] **1.1 ECR Repository 생성**
  - Terraform 모듈 작성 (`modules/ecr/`)
  - 3개 Repository 생성: billage-backend, billage-frontend, billage-ai
  - Lifecycle policy: 최근 10개 이미지만 보관 (비용 절감)
  - 이미지 push 시 자동 취약점 스캔 활성화
  - VPC Endpoint 생성 (Private Subnet에서 NAT 없이 ECR 접근)

- [ ] **1.2 Dockerfile 최종 검증**
  - Backend 이미지 빌드 테스트 (ARM64 호환 확인)
  - Frontend 이미지 빌드 테스트 (standalone 모드)
  - AI 이미지 빌드 테스트
  - 이미지 사이즈 측정: Backend < 300MB, Frontend < 200MB, AI < 250MB
  - .dockerignore로 민감 파일(.env, .git) 미포함 확인
  - 취약점 스캔 결과 Critical 0건 확인

- [ ] **1.3 로컬 docker-compose 통합 테스트**
  - docker-compose.dev.yml 작성 (전체 서비스 + MySQL + Redis)
  - 서비스 간 통신 검증: FE→BE, BE→AI, BE→MySQL, BE→Redis
  - 헬스체크 엔드포인트 동작 확인
  - 환경변수 주입 방식 확인

- [ ] **1.4 GitHub Actions CI 워크플로우**
  - paths-filter로 변경된 서비스만 빌드하도록 설정
  - AWS OIDC Provider 설정 (GitHub → AWS 신뢰 관계)
  - ECR 로그인 → 빌드 → push 자동화
  - 이미지 태그 전략: {semver}-{git-sha}
  - 빌드 캐시 설정 (빌드 시간 단축)

#### 완료 기준
- [ ] ECR에 3개 서비스 이미지 정상 push
- [ ] 취약점 스캔 Critical 0건
- [ ] main push 시 변경 서비스만 자동 빌드되는지 확인

---

### M2. 데이터 계층 구축 (RDS + Redis)

**목표**: RDS MySQL, ElastiCache Redis 구축 및 컨테이너 연결 검증
**선행 조건**: 없음 (M1과 병렬 가능)
**소요**: 2-3일

#### 태스크

- [ ] **2.1 RDS MySQL 프로비저닝**
  - Terraform 모듈 작성 (`modules/rds/`)
  - 스펙: db.t4g.medium, Single AZ, MySQL 8.0
  - Private Subnet 배치
  - Parameter Group: utf8mb4, max_connections=300, slow_query_log 활성화
  - 자동 백업: 7일 보관, 새벽 3시 실행
  - 삭제 방지 활성화
  - Security Group: Backend에서만 3306 허용

- [ ] **2.2 ElastiCache Redis 프로비저닝**
  - Terraform 모듈 작성 (`modules/elasticache/`)
  - 스펙: cache.t4g.micro, Single Node
  - Private Subnet 배치
  - 용도: 채팅 Pub/Sub, 세션 스토어 (필요 시)
  - Security Group: Backend에서만 6379 허용

- [ ] **2.3 시크릿 관리 설정**
  - Secrets Manager: RDS 패스워드 저장 + 30일 자동 로테이션
  - SSM Parameter Store: DB endpoint, Redis endpoint, S3 버킷명 등 비민감 설정값

- [ ] **2.4 연결 테스트 (Dev 환경 먼저)**
  - Dev에 먼저 RDS + Redis 생성
  - Docker 컨테이너 → RDS 연결 (CRUD 동작 확인)
  - Docker 컨테이너 → Redis 연결 (Pub/Sub 동작 확인)
  - IMDSv2 hop_limit=2 확인 (컨테이너에서 S3 Presigned URL 생성 가능한지)

#### 완료 기준
- [ ] RDS 정상 구동, 외부 연결 차단 확인
- [ ] Redis Pub/Sub 테스트 성공
- [ ] Docker 컨테이너 → RDS/Redis 연결 성공
- [ ] Secrets Manager 패스워드 조회 + 로테이션 동작

---

## Phase 2: 네트워크 & 컴퓨트 (Week 3-4)

---

### M3. v2 네트워크 설계 & ALB

**목표**: ALB + Target Group + 서브넷 구성 완성
**선행 조건**: M2 (RDS/Redis Private Subnet 배치)
**소요**: 3-4일

#### 태스크

- [ ] **3.1 서브넷 추가**
  - 현재: Public Subnet 1개 (10.1.1.0/24)
  - 추가: Public Subnet AZ-c (ALB 요구사항: 최소 2AZ)
  - 추가: Private Subnet 2개 (RDS Subnet Group 요구사항: 2AZ)
  - Route Table 설정 (Private → NAT Instance)

- [ ] **3.2 NAT Instance 구성**
  - t4g.nano ($3/월)
  - Private Subnet → 인터넷 아웃바운드 (AI→RunPod, 패치 등)
  - Source/Dest Check 비활성화

- [ ] **3.3 ALB 구성**
  - Terraform 모듈 작성 (`modules/alb/`)
  - HTTPS Listener + ACM 인증서
  - HTTP → HTTPS 리다이렉트
  - Path-based 라우팅:
    - /ws/* → Backend TG (WebSocket, priority 5)
    - /api/* → Backend TG (priority 10)
    - /ai/* → AI TG (priority 20)
    - /* → Frontend TG (default)

- [ ] **3.4 Target Group 설정**
  - Backend TG: 포트 8080, 헬스체크 /api/health, deregistration 300초 (WebSocket)
  - Frontend TG: 포트 3000, 헬스체크 /, deregistration 30초
  - AI TG: 포트 8000, 헬스체크 /ai/ping

- [ ] **3.5 v2 Security Group 설계**
  - ALB SG: 80, 443 ← 전체
  - Backend SG: 8080 ← ALB SG, 9100 ← Monitoring SG
  - Frontend SG: 3000 ← ALB SG, 9100 ← Monitoring SG
  - AI SG: 8000 ← ALB SG, 9100 ← Monitoring SG
  - RDS SG: 3306 ← Backend SG만
  - Redis SG: 6379 ← Backend SG만

- [ ] **3.6 내부 서비스 디스커버리**
  - Route 53 Private Hosted Zone: billage.internal
  - AI 서비스 DNS 등록 (BE → AI 내부 통신용)

#### 완료 기준
- [ ] ALB 생성 + HTTPS 리스너 동작
- [ ] 각 Target Group 헬스체크 설정 완료
- [ ] 2개 AZ에 걸친 Public/Private Subnet 생성
- [ ] Security Group 참조 관계 정상

---

### M4. Auto Scaling Group & Launch Template

**목표**: 서비스별 ASG + Docker 자동 시작 Launch Template 완성
**선행 조건**: M1 (ECR 이미지), M3 (ALB + Target Group)
**소요**: 4-5일

#### 태스크

- [ ] **4.1 IAM Role (EC2 Instance Profile)**
  - 권한: ECR pull, SSM 읽기, Secrets Manager 읽기, S3 접근, CloudWatch 로그

- [ ] **4.2 Backend Launch Template**
  - AMI: Ubuntu 24.04 ARM64
  - 타입: t4g.small
  - IMDSv2 필수, hop_limit=2
  - User Data: Docker 설치 → ECR 로그인 → 환경변수 조회(SSM/Secrets Manager) → 컨테이너 시작 → 모니터링 에이전트 시작

- [ ] **4.3 Frontend Launch Template**
  - 동일 구조, Next.js 컨테이너
  - 환경변수: NEXT_PUBLIC_API_URL (ALB DNS)

- [ ] **4.4 AI Launch Template**
  - 동일 구조, FastAPI 컨테이너
  - 환경변수: RunPod API Key (Secrets Manager)

- [ ] **4.5 ASG 설정**
  - Backend: min 2 / max 6, 헬스체크 유예 240초(JVM), CPU 70% 스케일링
  - Frontend: min 2 / max 3, 헬스체크 유예 120초, CPU 70%
  - AI: min 1 / max 2, 헬스체크 유예 120초, CPU 80%
  - 모든 ASG: ELB 헬스체크 기반, Scale-in cooldown 300초

- [ ] **4.6 스케일아웃 통합 테스트 (Dev)**
  - 부하 도구(k6 등)로 CPU 70% 이상 유지
  - ASG 인스턴스 추가 확인
  - 새 인스턴스 ALB 등록 확인
  - 헬스체크 통과까지 시간 측정 & 기록
  - 부하 제거 후 Scale-in 확인
  - Scale-in 시 WebSocket graceful shutdown 확인

- [ ] **4.7 (선택) Custom AMI 생성**
  - Docker + awscli 미리 설치된 AMI → 스케일아웃 4분 → 2분 단축
  - Packer로 AMI 빌드 자동화

#### 완료 기준
- [ ] 각 ASG에서 인스턴스 정상 시작 + Docker 컨테이너 구동
- [ ] ALB 통해 서비스 접근 가능 (v2 테스트 도메인)
- [ ] 부하 테스트로 Scale-out / in 동작 확인
- [ ] Scale-in 시 기존 연결 graceful 종료

---

## Phase 3: 파이프라인 & 모니터링 (Week 5)

---

### M5. CI/CD v2 파이프라인

**목표**: GitHub Actions → ECR → ASG Instance Refresh 전체 파이프라인 완성
**선행 조건**: M1, M4
**소요**: 2-3일

#### 태스크

- [ ] **5.1 GitHub OIDC 설정**
  - AWS에 GitHub OIDC Provider 등록
  - IAM Role: github-actions-deploy (ECR push + ASG refresh 권한)
  - 기존 SSH Key 기반 인증 제거

- [ ] **5.2 CI 워크플로우 최종판**
  - 변경 감지(paths-filter) → 해당 서비스만 빌드
  - OIDC 인증 → ECR push
  - 이미지 태그를 CD에 전달

- [ ] **5.3 CD 워크플로우 최종판**
  - Launch Template 새 버전 생성 (이미지 태그 반영)
  - ASG Instance Refresh 실행
  - 완료 대기 (timeout 15분)
  - Discord 알림 (시작/성공/실패)
  - 실패 시 Instance Refresh 취소 → 자동 롤백

- [ ] **5.4 수동 롤백 워크플로우**
  - workflow_dispatch로 수동 실행
  - 입력: 서비스명 + 롤백할 이미지 태그
  - 해당 태그로 Launch Template → Instance Refresh

- [ ] **5.5 E2E 배포 테스트 (Dev)**
  - 코드 수정 → push → CI → ECR → Instance Refresh → 새 버전 반영 확인
  - 전체 소요 시간 측정 & 기록
  - 의도적 실패: 헬스체크 실패 이미지 push → 롤백 동작 확인

#### 완료 기준
- [ ] main push → 자동 배포 → 새 버전 E2E 동작
- [ ] OIDC만으로 배포 (SSH Key 없음)
- [ ] 자동 롤백 동작 확인
- [ ] 수동 롤백 워크플로우 동작 확인

---

### M6. 모니터링 전환

**목표**: Prometheus/Grafana/Loki를 v2 동적 인스턴스에 맞게 전환
**선행 조건**: M4, Management VPC Peering
**소요**: 2-3일

#### 태스크

- [ ] **6.1 Prometheus EC2 Service Discovery**
  - 기존 static_configs(고정 IP) → ec2_sd_configs(태그 기반 동적 탐색)로 변경
  - Prometheus IAM에 ec2:DescribeInstances 권한 추가
  - 서비스별 태그(Service=backend 등) 기반 scrape
  - v1 scrape config 유지 (마이그레이션 기간 양쪽 모니터링)

- [ ] **6.2 컨테이너 메트릭 (cAdvisor)**
  - 각 인스턴스 cAdvisor(:8088) scrape 추가
  - 주요 메트릭: container CPU, Memory, restart count, network

- [ ] **6.3 로그 수집 (Promtail → Loki)**
  - Promtail이 Docker 컨테이너 로그 수집
  - 서비스명 + 인스턴스 ID 라벨 추가
  - Loki에서 서비스별 검색 가능 확인

- [ ] **6.4 ALB 메트릭 Grafana 연동**
  - CloudWatch 데이터소스 추가
  - ALB 패널: RequestCount, ResponseTime(p95), 5xx, HealthyHostCount

- [ ] **6.5 v2 Grafana 대시보드 구성**
  - Row 1: ASG 현황 + ALB 초당 요청 + 에러율
  - Row 2: ALB 응답시간, TG별 Healthy/Unhealthy, HTTP 상태코드 분포
  - Row 3: 인스턴스별 CPU/Memory + 컨테이너 메트릭 + 재시작 횟수
  - Row 4: RDS (Connections, QPS, CPU) + Redis (Clients, Memory, Pub/Sub)

- [ ] **6.6 알림 갱신**
  - ALB 5xx > 10건/5분 → Discord
  - ASG 인스턴스 수 = max → Discord ("스케일 한계 도달")
  - 컨테이너 재시작 > 0 → Discord
  - RDS FreeableMemory < 500MB → Discord

#### 완료 기준
- [ ] Prometheus가 v2 인스턴스 자동 탐색 + scrape
- [ ] Scale-out 시 새 인스턴스 Grafana에 자동 표시
- [ ] Loki에서 서비스별 컨테이너 로그 검색 가능
- [ ] ALB 메트릭 Grafana에 표시

---

## Phase 4: 데이터 마이그레이션 (Week 6)

---

### M7. MySQL → RDS 마이그레이션

**목표**: v1 호스트 MySQL 데이터를 RDS로 이전 (GTID Replica 기반, Write Freeze 최소화)
**선행 조건**: M2 (RDS 생성), M4 (v2 앱이 RDS 연결 가능)
**소요**: 3-4일 (리허설 포함)

**현황 (2026-02-13 기준)**:
- 전략 단일화 완료: GTID auto-position 기반 Replica 전환
- 리허설 환경 준비 완료: EC2/RDS/시딩/WAS 이중 구성/Nginx 스위칭
- 미완료: Round 실측 기록 정리, Prod 컷오버 실행

#### 태스크

- [x] **7.1 마이그레이션 방식 결정**
  - 최종 전략: **GTID auto-position 기반 MySQL Replication**
  - 기준 문서: `context/migration/01-db-migration.md`, `context/migration/db-migration-runbook.md`
  - 의사결정 근거 기록 완료 (포트폴리오 반영)

- [ ] **7.2 리허설 1차 (Dev 환경)**
  - Dev 호스트 MySQL → Dev RDS 마이그레이션 실행
  - 현재 상태: **리허설 환경 준비 완료, 실측 결과표 미기입**
  - Runbook 작성:
    - 사전: DB 백업, 데이터 크기/테이블 수/총 Row 기록
    - Step 1: 스키마 마이그레이션 → 소요 시간 기록
    - Step 2: 데이터 마이그레이션 → 소요 시간 기록
    - Step 3: DB endpoint 변경 + 재시작 → 소요 시간 기록
    - Step 4: 검증 스크립트 실행
    - 결과: 총 소요, 다운타임, 정합성 PASS/FAIL, 발견 이슈

- [ ] **7.3 데이터 검증 자동화 스크립트 작성**
  - 테이블 목록 비교 (소스 vs 타겟)
  - 각 테이블 Row count 비교
  - 외래키 무결성 검사 (고아 레코드 확인)
  - 최근 데이터 샘플링 (채팅 메시지 등 핵심 데이터)
  - 현재 상태: **런북 내 검증 명령 존재, 독립 실행 스크립트화 미완료**

- [ ] **7.4 리허설 2차 (이슈 수정 후)**
  - 1차 이슈 수정 반영
  - 소요 시간 재측정
  - 검증 스크립트 전체 PASS 확인
  - "Prod 실전 가능" 판단 근거

- [ ] **7.5 Prod 마이그레이션 실행**
  - 사전 공지: Discord + 서비스 내 배너 (새벽 2시 점검)
  - Runbook 따라 실행
  - 검증 스크립트 PASS 확인
  - v1 앱 DB endpoint → RDS로 변경 + 재시작
  - 정상 동작 확인 후 점검 해제

- [ ] **7.6 호스트 MySQL 2주 유지**
  - 즉시 삭제하지 않음 (롤백 가능 상태 유지)
  - 2주 관찰 후 서비스 중지

#### 완료 기준
- [ ] RDS에 전체 데이터 이전 완료
- [ ] 검증 스크립트 전체 PASS
- [ ] v1 앱이 RDS 바라보고 정상 운영
- [ ] 리허설 Runbook 2회분 기록 보존

---

## Phase 5: 트래픽 전환 (Week 7-9)

---

### M8. 점진적 트래픽 전환

**목표**: Route 53 Weighted Routing으로 v1 → v2 단계적 전환
**선행 조건**: M4, M5, M7 전체 완료
**소요**: 3주 (관찰 기간 포함)

#### 태스크

- [ ] **8.1 v2 내부 검증 (전환 전)**
  - v2 ALB에 테스트 도메인(v2.billages.com) 연결
  - E2E 수동 테스트:
    - 회원가입/로그인
    - 그룹 생성/참여
    - 물품 등록 (이미지 업로드 → S3)
    - 물품 목록/상세 조회
    - 채팅 (WebSocket 연결 + 메시지 송수신)
    - AI 추천 (이미지 분석)
    - 키워드 알림
  - 부하 테스트: 900 RPS, p95 < 500ms 확인, Auto Scaling 동작 확인

- [ ] **8.2 Route 53 Weighted Routing 설정**
  - Terraform 변수로 v1_weight / v2_weight 관리
  - TTL 60초 (빠른 전환/롤백)

- [ ] **8.3 Stage 1: 5% → v2 (3일 관찰)**
  - v1=95, v2=5
  - 모니터링 체크:
    - v2 에러율 < 1%
    - v2 응답시간 p95 < 500ms
    - 컨테이너 재시작 0회
    - WebSocket 정상
    - RDS 커넥션 정상
  - 롤백 기준: 에러율 > 5% 또는 p95 > 1초 → v2=0

- [ ] **8.4 Stage 2: 30% → v2 (3일 관찰)**
  - v1=70, v2=30
  - 동일 체크리스트
  - Auto Scaling 동작 확인

- [ ] **8.5 Stage 3: 80% → v2 (3일 관찰)**
  - v1=20, v2=80
  - v1 리소스 사용률 하락 확인

- [ ] **8.6 Stage 4: 100% 전환**
  - v1=0, v2=100
  - v1 트래픽 0 확인
  - **v1 인프라는 아직 유지** (롤백 가능)

#### 전환 기간 모니터링
- v1 vs v2 비교 대시보드:
  - 트래픽 비율 추이
  - 에러율 비교
  - 응답시간 비교
  - 인프라 현황 (v1 싱글 인스턴스 vs v2 ASG)

#### 완료 기준
- [ ] v2가 100% 트래픽, 안정 운영
- [ ] 전환 기간 사용자 영향 0 (에러/다운타임 없음)
- [ ] 각 Stage별 모니터링 기록 보존

---

### M9. v1 인프라 정리

**목표**: v2 안정 확인 후 v1 안전 제거
**선행 조건**: M8 완료 + 최소 2주 안정 운영
**소요**: 1일 실행 + 2주 관찰

#### 태스크

- [ ] **9.1 v1 최종 백업**
  - EBS 스냅샷 생성
  - MySQL 최종 dump
  - Nginx 설정, systemd 서비스 파일, 배포 스크립트 백업 (포트폴리오 자료)

- [ ] **9.2 v1 서비스 중지 (삭제가 아닌 중지)**
  - 애플리케이션 + MySQL 서비스 중지
  - Route 53에서 v1 레코드 제거
  - 인스턴스는 아직 terminate하지 않음

- [ ] **9.3 1주 관찰**
  - v2만으로 운영
  - 문제 시 v1 인스턴스 재시작으로 즉시 복구 가능

- [ ] **9.4 v1 최종 제거 (Point of No Return)**
  - EC2 terminate + Elastic IP 해제
  - v1 Security Group 정리
  - v1 CI/CD 워크플로우 제거 (SSH 기반)
  - GitHub Secrets에서 EC2_SSH_KEY 삭제

- [ ] **9.5 Terraform State 정리**
  - v1 리소스 state에서 제거 또는 아카이브
  - v2를 주 state로 전환
  - 모듈 구조 정리

- [ ] **9.6 포트폴리오 최종 정리**
  - 마이그레이션 전체 과정 문서화
  - v1 vs v2 비교 (비용, 성능, 가용성)
  - 리허설 Runbook 포함
  - 트래픽 전환 Grafana 스크린샷 첨부

#### 완료 기준
- [ ] v1 인프라 완전 제거
- [ ] v2만으로 안정 운영 2주 이상
- [ ] Terraform state 정리 완료
- [ ] 마이그레이션 포트폴리오 문서 완성

---

## 리스크 매트릭스

| 리스크 | 확률 | 영향도 | 대응 |
|--------|------|--------|------|
| DB 마이그레이션 중 데이터 유실 | 낮음 | 치명적 | 리허설 2회 + 검증 스크립트 + 호스트 MySQL 2주 유지 |
| v2 인스턴스 시작 실패 | 중간 | 높음 | Custom AMI, User Data 에러 핸들링 |
| WebSocket 연결 끊김 | 중간 | 중간 | 클라이언트 재연결 로직 + deregistration delay 300초 |
| 트래픽 전환 후 성능 저하 | 낮음 | 높음 | Route 53 weight 즉시 롤백 (TTL 60초) |
| ECR 이미지 pull 실패 | 낮음 | 높음 | VPC Endpoint, Custom AMI에 이미지 포함 |
| 비용 초과 | 중간 | 중간 | ASG max 제한 + 비용 알림 설정 |

---

*문서 버전: 2.0 (코드 제거, 일정 관리용)*
*작성일: 2026-02-09*
