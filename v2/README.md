# Billage v2 Infrastructure

Auto Scaling + ALB 기반의 확장 가능한 아키텍처

## 아키텍처 개요

```
                           Internet
                              │
                              ▼
                      ┌───────────────┐
                      │     ALB       │
                      │  (HTTPS:443)  │
                      └───────┬───────┘
                              │
            ┌─────────────────┼─────────────────┐
            │                 │                 │
            ▼                 ▼                 ▼
      ┌───────────┐    ┌───────────┐    ┌───────────┐
      │ Frontend  │    │  Backend  │    │    AI     │
      │   ASG     │    │    ASG    │    │   ASG     │
      │  (2-3)    │    │   (2-6)   │    │  (1-2)    │
      └───────────┘    └─────┬─────┘    └───────────┘
                              │
                   ┌──────────┴──────────┐
                   │                     │
                   ▼                     ▼
            ┌───────────┐         ┌───────────┐
            │    RDS    │         │   Redis   │
            │  MySQL    │         │ ElastiCache│
            └───────────┘         └───────────┘
```

## 디렉토리 구조

```
v2/
└── envs/
    ├── dev/
    │   ├── main.tf
    │   ├── variables.tf
    │   ├── outputs.tf
    │   └── backend.tf
    └── prod/

# 공용 인프라는 shared/ 디렉토리 사용
shared/
├── management/          # VPN + 모니터링 (v1, v2 공통)
├── s3-images-dev/
└── s3-images-prod/
```

## v1 대비 변경사항

| 항목 | v1 (Big Bang) | v2 (Scalable) |
|------|---------------|---------------|
| 컴퓨트 | 단일 EC2 | ASG (서비스별 분리) |
| 로드밸런싱 | Nginx | ALB |
| 데이터베이스 | Host MySQL | RDS MySQL |
| 캐시/Pub-Sub | - | ElastiCache Redis |
| 배포 방식 | SSH + 재시작 | ECR + Instance Refresh |
| 확장성 | 수동 | Auto Scaling |
| 가용성 | Single AZ | Multi-AZ |

## 사용법

```bash
cd v2/envs/dev
terraform init
terraform plan
terraform apply
```

## State 관리

v1과 v2는 별도의 state key 사용:
- v1: `dev/terraform.tfstate`
- v2: `v2/dev/terraform.tfstate`

## 관련 이슈

- [#58 디렉토리 구조 분리](https://github.com/100-hours-a-week/6-team-team6-cloud/issues/58)
- [#47-#55 v2 마이그레이션 마일스톤](https://github.com/100-hours-a-week/6-team-team6-cloud/issues)