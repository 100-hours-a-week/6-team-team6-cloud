# [Dev 환경] v2 인프라 전환 완료 공지

> 일시: 2026-03-01
> 작업자: ktb6
> 대상: `dev.billages.com`

---

## 요약

`dev.billages.com`이 v2 인프라(ALB + ASG + RDS)로 전환 완료되었습니다.

---

## 변경 사항

| 항목 | v1 (이전) | v2 (현재) |
|------|-----------|-----------|
| 아키텍처 | 단일 EC2 (모든 서비스 동거) | ALB + ASG (서비스별 분리) |
| DB | EC2 내 MySQL | RDS MySQL 8.0 (관리형) |
| 배포 | 수동/중단 배포 | ASG Instance Refresh (무중단) |
| DNS | `dev.billages.com` → EC2 EIP | `dev.billages.com` → ALB |

---

## 접속 정보

| 서비스 | URL |
|--------|-----|
| Frontend | `https://dev.billages.com` |
| Backend API | `https://api-v2.billages.com` |
| Frontend (별칭) | `https://v2.dev.billages.com` (동일 ALB) |

---

## DB 이관 결과

v1 MySQL → RDS mysqldump 직접 이관 완료. 전수 검증 일치 확인:

| 테이블 | v1 | RDS | 결과 |
|--------|-----|-----|------|
| users | 59 | 59 | 일치 |
| post | 74 | 74 | 일치 |
| chatroom | 35 | 35 | 일치 |
| chat_message | 2,066 | 2,066 | 일치 |

- RDS endpoint: `billage-dev-v2-mysql.cpigi2qskxj3.ap-northeast-2.rds.amazonaws.com`
- dump 파일: `/tmp/billage-dev-20260301.sql.gz` (44KB, v1 EC2에 보존)

---

## 발견된 이슈 및 조치

### 1. CI/CD 무중단 배포 이슈 (해결)

- **문제**: ASG max=1, MinHealthyPercentage=0 → 배포 시 기존 인스턴스를 먼저 종료 후 새 인스턴스 기동 (중단 배포)
- **원인**: max_size=1이면 새 인스턴스를 먼저 띄울 수 없음
- **조치**: Terraform 코드 수정
  - `max_size`: 1 → 2 (배포 시 일시적 2대 허용, 평소 1대 유지)
  - `min_healthy_percentage`: 0 → 100 (새 인스턴스 healthy 확인 후 기존 종료)
  - 대상: BE/FE/AI ASG 모두
  - 파일: `v2/envs/dev/variables.tf`, `v2/envs/dev/main.tf`
- **상태**: 코드 수정 완료, `terraform apply` 반영 필요

### 2. AI 서비스 unhealthy (확인 필요)

- AI Target Group 헬스체크 실패 (502 Bad Gateway)
- `/ai/*` 경로 접속 불가
- 마이그레이션 자체와는 무관한 이슈, 별도 확인 예정

---

## 롤백 대비

- v1 EC2 인스턴스: **running 상태 유지** (즉시 롤백 가능)
- v1 EIP: `43.200.94.221` (보존 중)
- v1 MySQL 데이터: 보존 중
- 롤백 방법: Route 53 `dev.billages.com` → `43.200.94.221`(v1 EIP)로 원복

---

## 안내

- 이상 발견 시 즉시 알려주세요
- `v2.dev.billages.com`도 동일하게 접속 가능합니다
- Backend API는 `api-v2.billages.com` 서브도메인으로 접근합니다
