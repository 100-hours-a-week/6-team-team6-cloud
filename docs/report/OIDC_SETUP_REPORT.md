# GitHub Actions OIDC 인증 구축 보고서

> 작성일: 2026-02-10
> 작성자: Billage 인프라팀
> 버전: 1.0

---

## 1. 개요

### 1.1 배경
기존 GitHub Actions CI/CD 파이프라인은 AWS Access Key를 사용하여 인증했습니다. 이 방식은 다음과 같은 보안 문제가 있습니다:

- **장기 자격증명**: Access Key는 수동으로 교체하지 않으면 영구적으로 유효
- **유출 위험**: GitHub Secrets에 저장된 키가 유출될 경우 즉시 악용 가능
- **관리 부담**: 키 교체, 권한 변경 시 모든 레포에서 수동 업데이트 필요

### 1.2 목표
- **Keyless CI/CD**: 장기 자격증명 제거
- **임시 자격증명**: 1시간 유효한 토큰으로 자동 만료
- **최소 권한 원칙**: 레포/브랜치별 세분화된 접근 제어
- **중앙 집중 관리**: Terraform으로 권한 정책 일원화

---

## 2. OIDC 인증 아키텍처

### 2.1 인증 흐름

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    GitHub Actions OIDC 인증 흐름                              │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  [GitHub Actions Workflow]                                                  │
│           │                                                                  │
│           │ 1. JWT 토큰 요청                                                  │
│           ▼                                                                  │
│  ┌─────────────────────────────┐                                            │
│  │ GitHub OIDC Provider        │                                            │
│  │ token.actions.githubusercontent.com                                      │
│  └─────────────────────────────┘                                            │
│           │                                                                  │
│           │ 2. JWT 토큰 발급 (레포/브랜치 정보 포함)                           │
│           ▼                                                                  │
│  [GitHub Actions Workflow]                                                  │
│           │                                                                  │
│           │ 3. AssumeRoleWithWebIdentity (JWT 제출)                          │
│           ▼                                                                  │
│  ┌─────────────────────────────┐                                            │
│  │ AWS IAM                     │                                            │
│  │                             │                                            │
│  │  ┌───────────────────────┐  │                                            │
│  │  │ OIDC Provider         │  │  4. JWT 검증                               │
│  │  │ (GitHub 신뢰)          │◄─┼──────────────────┐                         │
│  │  └───────────────────────┘  │                  │                         │
│  │           │                 │                  │                         │
│  │           │ 5. 조건 확인    │     ┌────────────┴────────────┐            │
│  │           ▼                 │     │ 검증 항목:              │            │
│  │  ┌───────────────────────┐  │     │ - aud: sts.amazonaws.com│            │
│  │  │ IAM Role              │  │     │ - sub: repo:org/repo:*  │            │
│  │  │ github-actions-role   │  │     │ - 브랜치 패턴 매칭       │            │
│  │  └───────────────────────┘  │     └─────────────────────────┘            │
│  │           │                 │                                            │
│  └───────────┼─────────────────┘                                            │
│              │                                                               │
│              │ 6. 임시 자격증명 발급 (1시간 유효)                              │
│              ▼                                                               │
│  [GitHub Actions Workflow]                                                  │
│              │                                                               │
│              │ 7. AWS 리소스 접근 (ECR, SSM, S3 등)                          │
│              ▼                                                               │
│  ┌─────────────────────────────────────────────────────────────┐            │
│  │ AWS Resources                                                │            │
│  │  ┌─────────┐  ┌─────────┐  ┌─────────┐  ┌─────────┐        │            │
│  │  │   ECR   │  │   SSM   │  │   ASG   │  │   S3    │        │            │
│  │  └─────────┘  └─────────┘  └─────────┘  └─────────┘        │            │
│  └─────────────────────────────────────────────────────────────┘            │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 2.2 JWT 토큰 구조

GitHub Actions에서 발급하는 JWT 토큰에는 다음 클레임이 포함됩니다:

| 클레임 | 설명 | 예시 |
|--------|------|------|
| `iss` | 토큰 발급자 | `https://token.actions.githubusercontent.com` |
| `aud` | 토큰 수신자 | `sts.amazonaws.com` |
| `sub` | 주체 (레포+브랜치) | `repo:100-hours-a-week/6-team-team6-be:ref:refs/heads/main` |
| `repository` | 레포지토리 | `100-hours-a-week/6-team-team6-be` |
| `ref` | Git 참조 | `refs/heads/main` |
| `actor` | 실행자 | `kimyuchan-k1` |

---

## 3. 구현 상세

### 3.1 Terraform 리소스 구조

```
shared/oidc/
├── main.tf         # OIDC Provider, IAM Role, Policies
├── variables.tf    # 레포/브랜치 설정
├── outputs.tf      # Role ARN 출력
└── backend.tf      # S3 Backend 설정
```

### 3.2 허용된 레포지토리 및 브랜치

| 레포지토리 | 허용 브랜치 | 용도 |
|-----------|------------|------|
| `100-hours-a-week/6-team-team6-be` | `main`, `dev` | Backend 배포 |
| `100-hours-a-week/6-team-team6-fe` | `develop`, `main` | Frontend 배포 |
| `100-hours-a-week/6-team-team6-ai` | `develop`, `main` | AI 서버 배포 |

### 3.3 IAM Role Trust Policy

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::ACCOUNT_ID:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
        },
        "StringLike": {
          "token.actions.githubusercontent.com:sub": [
            "repo:100-hours-a-week/6-team-team6-be:ref:refs/heads/main",
            "repo:100-hours-a-week/6-team-team6-be:ref:refs/heads/dev",
            "repo:100-hours-a-week/6-team-team6-fe:ref:refs/heads/develop",
            "repo:100-hours-a-week/6-team-team6-fe:ref:refs/heads/main",
            "repo:100-hours-a-week/6-team-team6-ai:ref:refs/heads/develop",
            "repo:100-hours-a-week/6-team-team6-ai:ref:refs/heads/main"
          ]
        }
      }
    }
  ]
}
```

---

## 4. IAM 권한 정책

### 4.1 ECR 권한

Docker 이미지 Push/Pull을 위한 권한:

| 권한 | 리소스 | 용도 |
|------|--------|------|
| `ecr:GetAuthorizationToken` | `*` | ECR 로그인 |
| `ecr:BatchCheckLayerAvailability` | `billage-*` 레포지토리 | 레이어 확인 |
| `ecr:PutImage` | `billage-*` 레포지토리 | 이미지 푸시 |
| `ecr:BatchGetImage` | `billage-*` 레포지토리 | 이미지 풀 |

### 4.2 SSM Parameter Store 권한

환경변수 및 시크릿 조회:

| 권한 | 리소스 | 용도 |
|------|--------|------|
| `ssm:GetParameter` | `/billage/*` | 단일 파라미터 조회 |
| `ssm:GetParameters` | `/billage/*` | 다중 파라미터 조회 |
| `ssm:GetParametersByPath` | `/billage/*` | 경로별 조회 |

### 4.3 ASG Instance Refresh 권한 (v2 배포용)

Auto Scaling Group 롤링 배포:

| 권한 | 조건 | 용도 |
|------|------|------|
| `autoscaling:StartInstanceRefresh` | `Project=billage` 태그 | 인스턴스 갱신 시작 |
| `autoscaling:DescribeInstanceRefreshes` | `Project=billage` 태그 | 갱신 상태 확인 |
| `ec2:CreateLaunchTemplateVersion` | - | 새 AMI로 템플릿 업데이트 |

### 4.4 S3 접근 권한

배포 아티팩트 및 정적 자산:

| 권한 | 리소스 | 용도 |
|------|--------|------|
| `s3:GetObject` | `billage-*` 버킷 | 객체 다운로드 |
| `s3:PutObject` | `billage-*` 버킷 | 객체 업로드 |
| `s3:ListBucket` | `billage-*` 버킷 | 버킷 목록 조회 |

---

## 5. GitHub Actions Workflow 설정

### 5.1 Workflow 예시

```yaml
name: Deploy to AWS

on:
  push:
    branches: [main, dev]  # 허용된 브랜치만

permissions:
  id-token: write   # OIDC 토큰 요청 필수
  contents: read

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Configure AWS credentials
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::ACCOUNT_ID:role/billage-github-actions-role
          aws-region: ap-northeast-2

      - name: Login to ECR
        uses: aws-actions/amazon-ecr-login@v2

      - name: Build and Push
        run: |
          docker build -t $ECR_REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG .
          docker push $ECR_REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG
```

### 5.2 주요 설정 항목

| 설정 | 값 | 설명 |
|------|-----|------|
| `permissions.id-token` | `write` | OIDC 토큰 요청에 필수 |
| `role-to-assume` | `billage-github-actions-role` | Terraform output으로 확인 |
| `aws-region` | `ap-northeast-2` | 서울 리전 |

---

## 6. 보안 강화 효과

### 6.1 Before vs After

| 항목 | Before (Access Key) | After (OIDC) |
|------|---------------------|--------------|
| 자격증명 수명 | 영구 (수동 교체) | 1시간 (자동 만료) |
| 유출 시 영향 | 즉시 악용 가능 | 토큰 만료로 제한적 |
| 권한 범위 | 키 보유자 전체 | 레포/브랜치별 제한 |
| 키 관리 | 수동 교체, Secrets 저장 | 관리 불필요 |
| 감사 추적 | CloudTrail 기본 | CloudTrail + GitHub 로그 |

### 6.2 공격 시나리오 대응

| 시나리오 | Access Key | OIDC |
|----------|------------|------|
| Secrets 유출 | AWS 전체 접근 가능 | 유출된 것 없음 (키 미저장) |
| 악성 PR 빌드 | 키 접근 가능 | 브랜치 조건 불충족으로 거부 |
| 퇴사자 접근 | 키 교체 전까지 접근 가능 | GitHub 권한 제거 시 즉시 차단 |

---

## 7. 운영 가이드

### 7.1 새 레포지토리 추가

`shared/oidc/variables.tf`에 레포 추가:

```hcl
variable "allowed_repo_branches" {
  default = {
    "100-hours-a-week/6-team-team6-be" = ["main", "dev"]
    "100-hours-a-week/6-team-team6-fe" = ["develop", "main"]
    "100-hours-a-week/6-team-team6-ai" = ["develop", "main"]
    # 새 레포 추가
    "100-hours-a-week/6-team-team6-new" = ["main"]
  }
}
```

적용:
```bash
cd shared/oidc
terraform apply
```

### 7.2 트러블슈팅

| 에러 | 원인 | 해결 |
|------|------|------|
| `Not authorized to perform sts:AssumeRoleWithWebIdentity` | 브랜치 조건 불일치 | 허용 브랜치 확인 |
| `Audience in the token doesn't match` | aud 클레임 불일치 | workflow에 audience 설정 확인 |
| `The OpenID Connect provider is not found` | OIDC Provider 미생성 | `terraform apply` 재실행 |

### 7.3 Role ARN 확인

```bash
cd shared/oidc
terraform output github_actions_role_arn
```

---

## 8. 참고 자료

- [GitHub OIDC 공식 문서](https://docs.github.com/en/actions/deployment/security-hardening-your-deployments/configuring-openid-connect-in-amazon-web-services)
- [AWS IAM OIDC Provider](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_providers_create_oidc.html)
- [configure-aws-credentials Action](https://github.com/aws-actions/configure-aws-credentials)

---

## 9. 변경 이력

| 버전 | 날짜 | 변경 내용 |
|------|------|----------|
| 1.0 | 2026-02-10 | 최초 작성 |