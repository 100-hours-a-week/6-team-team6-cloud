# ECR (Elastic Container Registry) 구축 보고서

> 작성일: 2026-02-10
> 작성자: Billage 인프라팀
> 버전: 1.0

---

## 1. 개요

### 1.1 배경
컨테이너 기반 배포를 위한 Docker 이미지 저장소가 필요합니다. AWS ECR을 사용하여 다음을 달성합니다:

- **Private Registry**: 내부 이미지 보안 관리
- **IAM 통합**: OIDC 기반 인증으로 GitHub Actions에서 안전하게 접근
- **자동 정리**: Lifecycle Policy로 오래된 이미지 자동 삭제
- **보안 스캔**: 이미지 Push 시 취약점 자동 스캔

### 1.2 목표
- 서비스별 독립적인 Repository 구성
- GitHub Actions CI/CD 파이프라인 연동
- 이미지 버전 관리 및 자동 정리

---

## 2. Repository 구조

### 2.1 생성되는 Repository

```
ECR Registry (AWS Account)
├── billage-be          # Backend (Spring Boot)
├── billage-fe          # Frontend (Next.js)
└── billage-ai          # AI Server (FastAPI)
```

### 2.2 이미지 태깅 전략

| 태그 패턴 | 용도 | 예시 |
|-----------|------|------|
| `latest` | 최신 빌드 | `billage-be:latest` |
| `main` | main 브랜치 빌드 | `billage-be:main` |
| `dev` | dev 브랜치 빌드 | `billage-be:dev` |
| `v{버전}` | 릴리즈 버전 | `billage-be:v1.2.3` |
| `{commit-sha}` | 특정 커밋 | `billage-be:abc1234` |

---

## 3. 설정 상세

### 3.1 Repository 설정

| 설정 | 값 | 설명 |
|------|-----|------|
| `image_tag_mutability` | MUTABLE | 같은 태그 덮어쓰기 허용 |
| `scan_on_push` | true | Push 시 자동 취약점 스캔 |
| `encryption_type` | AES256 | 이미지 암호화 |

### 3.2 Lifecycle Policy

오래된 이미지 자동 삭제로 스토리지 비용 절감:

```
┌─────────────────────────────────────────────────────────────┐
│                    Lifecycle Policy                          │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  Rule 1: 태그된 이미지 (v*, main, dev, develop, release)     │
│  ─────────────────────────────────────────────────────────   │
│  → 최근 10개 유지, 나머지 삭제                                │
│                                                              │
│  Rule 2: Untagged 이미지                                     │
│  ─────────────────────────────────────────────────────────   │
│  → 7일 경과 후 삭제                                          │
│                                                              │
│  Rule 3: 전체 이미지                                         │
│  ─────────────────────────────────────────────────────────   │
│  → 최근 30개 유지, 나머지 삭제                                │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

### 3.3 Repository Policy

GitHub Actions OIDC Role에 Push/Pull 권한 부여:

```json
{
  "Statement": [
    {
      "Sid": "AllowGitHubActions",
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::ACCOUNT_ID:role/billage-github-actions-role"
      },
      "Action": [
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchGetImage",
        "ecr:BatchCheckLayerAvailability",
        "ecr:PutImage",
        "ecr:InitiateLayerUpload",
        "ecr:UploadLayerPart",
        "ecr:CompleteLayerUpload"
      ]
    }
  ]
}
```

---

## 4. GitHub Actions 연동

### 4.1 Workflow 예시

```yaml
name: Build and Push to ECR

on:
  push:
    branches: [main, dev]

permissions:
  id-token: write
  contents: read

env:
  AWS_REGION: ap-northeast-2
  ECR_REPOSITORY: billage-be

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Configure AWS credentials (OIDC)
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::ACCOUNT_ID:role/billage-github-actions-role
          aws-region: ${{ env.AWS_REGION }}

      - name: Login to Amazon ECR
        id: login-ecr
        uses: aws-actions/amazon-ecr-login@v2

      - name: Build, tag, and push image
        env:
          ECR_REGISTRY: ${{ steps.login-ecr.outputs.registry }}
          IMAGE_TAG: ${{ github.sha }}
        run: |
          docker build -t $ECR_REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG .
          docker build -t $ECR_REGISTRY/$ECR_REPOSITORY:${{ github.ref_name }} .
          docker push $ECR_REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG
          docker push $ECR_REGISTRY/$ECR_REPOSITORY:${{ github.ref_name }}
```

### 4.2 Multi-Architecture 빌드 (선택)

ARM64 + AMD64 지원이 필요한 경우:

```yaml
- name: Set up Docker Buildx
  uses: docker/setup-buildx-action@v3

- name: Build and push (multi-arch)
  uses: docker/build-push-action@v5
  with:
    context: .
    platforms: linux/amd64,linux/arm64
    push: true
    tags: |
      ${{ steps.login-ecr.outputs.registry }}/billage-be:${{ github.sha }}
      ${{ steps.login-ecr.outputs.registry }}/billage-be:${{ github.ref_name }}
```

---

## 5. 로컬 개발 환경

### 5.1 ECR 로그인

```bash
# AWS CLI로 로그인
aws ecr get-login-password --region ap-northeast-2 | \
  docker login --username AWS --password-stdin \
  ACCOUNT_ID.dkr.ecr.ap-northeast-2.amazonaws.com
```

### 5.2 이미지 Pull

```bash
# 최신 이미지 가져오기
docker pull ACCOUNT_ID.dkr.ecr.ap-northeast-2.amazonaws.com/billage-be:main
```

### 5.3 이미지 Push (수동)

```bash
# 빌드
docker build -t billage-be:v1.0.0 .

# 태그
docker tag billage-be:v1.0.0 \
  ACCOUNT_ID.dkr.ecr.ap-northeast-2.amazonaws.com/billage-be:v1.0.0

# 푸시
docker push ACCOUNT_ID.dkr.ecr.ap-northeast-2.amazonaws.com/billage-be:v1.0.0
```

---

## 6. 배포 연동

### 6.1 EC2에서 이미지 Pull

EC2 Instance Profile에 ECR 읽기 권한 필요:

```json
{
  "Effect": "Allow",
  "Action": [
    "ecr:GetAuthorizationToken",
    "ecr:BatchCheckLayerAvailability",
    "ecr:GetDownloadUrlForLayer",
    "ecr:BatchGetImage"
  ],
  "Resource": "*"
}
```

### 6.2 Docker Compose 예시

```yaml
# docker-compose.yml
services:
  backend:
    image: ${ECR_REGISTRY}/billage-be:${IMAGE_TAG:-latest}
    ports:
      - "8080:8080"
```

배포 스크립트:
```bash
#!/bin/bash
aws ecr get-login-password --region ap-northeast-2 | docker login --username AWS --password-stdin $ECR_REGISTRY
docker-compose pull
docker-compose up -d
```

---

## 7. 모니터링

### 7.1 취약점 스캔 결과

AWS Console에서 확인:
- ECR → Repositories → billage-be → Images → Scan status

### 7.2 CloudWatch 메트릭

| 메트릭 | 설명 |
|--------|------|
| `RepositoryPullCount` | 이미지 Pull 횟수 |
| `ImagePushCount` | 이미지 Push 횟수 |
| `ImageScanFindingsCount` | 취약점 발견 개수 |

---

## 8. 비용 최적화

### 8.1 예상 비용

| 항목 | 비용 |
|------|------|
| 스토리지 | $0.10/GB/월 |
| 데이터 전송 (같은 리전) | 무료 |
| 데이터 전송 (인터넷) | $0.09/GB |

### 8.2 비용 절감 방법

- **Lifecycle Policy**: 오래된 이미지 자동 삭제
- **Multi-stage Build**: 이미지 크기 최소화
- **레이어 캐싱**: 변경된 레이어만 Push

---

## 9. Terraform 리소스

### 9.1 파일 구조

```
shared/ecr/
├── main.tf         # Repository, Lifecycle Policy, Repository Policy
├── variables.tf    # 서비스 목록
├── backend.tf      # S3 Backend
└── outputs.tf      # Repository URLs
```

### 9.2 적용 방법

```bash
cd shared/ecr
terraform init
terraform apply
```

### 9.3 Output 확인

```bash
terraform output repository_urls
# {
#   "ai" = "ACCOUNT_ID.dkr.ecr.ap-northeast-2.amazonaws.com/billage-ai"
#   "be" = "ACCOUNT_ID.dkr.ecr.ap-northeast-2.amazonaws.com/billage-be"
#   "fe" = "ACCOUNT_ID.dkr.ecr.ap-northeast-2.amazonaws.com/billage-fe"
# }
```

---

## 10. TODO (미완료 작업)

### VPC Endpoint 생성 (필수)

현재 Private Subnet의 EC2에서 ECR 접근이 불가능합니다. CD 파이프라인 동작을 위해 VPC Endpoint 생성이 필요합니다.

**필요한 Endpoint:**

| Endpoint | 서비스 | 타입 | 용도 |
|----------|--------|------|------|
| ECR API | `com.amazonaws.ap-northeast-2.ecr.api` | Interface | ECR API 호출 |
| ECR DKR | `com.amazonaws.ap-northeast-2.ecr.dkr` | Interface | Docker Registry |
| S3 | `com.amazonaws.ap-northeast-2.s3` | Gateway | 이미지 레이어 저장소 |

**예상 비용:** ~$22/월 (Interface Endpoint 2개)

**현재 상태:**
```
EC2 (Private Subnet) ──X──→ ECR (인터넷 경로 없음)
                       ↑
                 NAT Gateway 없음
                 VPC Endpoint 없음
```

**해결 후:**
```
EC2 (Private Subnet) ──→ VPC Endpoint ──→ ECR (Private 연결)
```

---

## 11. 참고 자료

- [AWS ECR 공식 문서](https://docs.aws.amazon.com/AmazonECR/latest/userguide/what-is-ecr.html)
- [ECR Lifecycle Policy](https://docs.aws.amazon.com/AmazonECR/latest/userguide/LifecyclePolicies.html)
- [amazon-ecr-login Action](https://github.com/aws-actions/amazon-ecr-login)
- [VPC Endpoints for ECR](https://docs.aws.amazon.com/AmazonECR/latest/userguide/vpc-endpoints.html)

---

## 12. 변경 이력

| 버전 | 날짜 | 변경 내용 |
|------|------|----------|
| 1.0 | 2026-02-10 | 최초 작성 |