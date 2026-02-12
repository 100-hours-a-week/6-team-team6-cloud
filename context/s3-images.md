# S3 이미지 저장소

## 개요

Billage 프로젝트의 이미지 저장용 S3 버킷입니다. Presigned URL 방식으로 프론트엔드에서 직접 업로드/다운로드합니다.

- **리전**: ap-northeast-2 (서울)
- **접근 방식**: Presigned URL (퍼블릭 차단)
- **적용 상태**: Dev, Prod 모두 적용 완료 (2025-01-27)

| 환경 | 버킷명 | Terraform 경로 |
|------|--------|----------------|
| Dev | `billage-images-dev` | `envs/s3-images-dev/` |
| Prod | `billage-images-prod` | `envs/s3-images-prod/` |

---

## 환경 분리 전략

S3 이미지 버킷은 **환경별로 분리**하여 데이터를 격리합니다. 로컬 개발 시에는 dev 버킷을 공유합니다.

| 환경 | 버킷명 | Terraform 경로 | State 버킷 | CORS Origin |
|------|--------|----------------|------------|-------------|
| 로컬 개발 | `billage-images-dev` | - | - | - (dev 버킷 공유, IAM User Access Key 사용) |
| Dev 서버 | `billage-images-dev` | `envs/s3-images-dev/` | `billage-terraform-state-dev` | `localhost:3000`, `dev.billages.com` |
| Prod 서버 | `billage-images-prod` | `envs/s3-images-prod/` | `billage-terraform-state-prod` | `www.billages.com` |

```
envs/
├── dev/                  # dev EC2/VPC 인프라 (state: billage-terraform-state-dev)
├── prod/                 # prod EC2/VPC 인프라 (state: billage-terraform-state-prod)
├── s3-images-dev/        # dev S3 이미지   (state: billage-terraform-state-dev)
└── s3-images-prod/       # prod S3 이미지  (state: billage-terraform-state-prod)
```

---

## 아키텍처

```
                        Presigned URL Flow
                        ==================

 ┌──────────┐    1. 업로드 요청     ┌──────────────┐
 │          │ ──────────────────► │              │
 │ Frontend │                     │   Backend    │
 │ (Next.js)│ ◄────────────────── │ (Spring Boot)│
 │          │  2. Presigned URL   │              │
 └────┬─────┘                     └──────┬───────┘
      │                                  │
      │ 3. PUT (이미지 업로드)            │ IAM 자격증명으로
      │    GET (이미지 다운로드)          │ Presigned URL 생성
      │                                  │
      ▼                                  ▼
 ┌─────────────────────────────────────────────┐
 │              S3: billage-images-dev          │
 │                                             │
 │  - Public Access: 차단                      │
 │  - Encryption: AES-256                      │
 │  - CORS: localhost:3000, dev.billages.com   │
 │  - Versioning: Suspended                    │
 └─────────────────────────────────────────────┘
```

### 인증 흐름

| 환경 | 인증 방식 | 설명 |
|------|-----------|------|
| 로컬 개발 | IAM User Access Key | 환경변수 `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` 설정 |
| EC2 서버 | IAM Instance Profile | 자동 인증, Key 불필요 |

AWS SDK의 **Default Credential Provider Chain**이 환경에 따라 자동으로 적합한 인증을 선택합니다. 백엔드 코드 변경 없이 로컬/서버 모두 동작합니다.

---

## 리소스 상세

> `envs/s3-images-dev/` 디렉토리에서 `terraform output`으로 확인 가능합니다.

### 1. S3 Bucket

| 속성 | Dev | Prod |
|------|-----|------|
| Bucket Name | `billage-images-dev` | `billage-images-prod` |
| Region | ap-northeast-2 | ap-northeast-2 |
| Public Access | 전체 차단 (Block All) | 전체 차단 (Block All) |
| Encryption | AES-256 (SSE-S3) | AES-256 (SSE-S3) |
| Versioning | Suspended | **Enabled** (삭제 방지) |

### 2. CORS 설정

| 속성 | Dev | Prod |
|------|-----|------|
| Allowed Origins | `http://localhost:3000`, `https://dev.billages.com` | `https://www.billages.com` |
| Allowed Methods | GET, PUT, POST, DELETE, HEAD | GET, PUT, POST, DELETE, HEAD |
| Allowed Headers | * | * |
| Expose Headers | ETag, Content-Type, Content-Length | ETag, Content-Type, Content-Length |
| Max Age | 3600초 | 3600초 |

### 3. IAM Policy

| 속성 | Dev | Prod |
|------|-----|------|
| Policy Name | `billage-dev-s3-images-policy` | `billage-prod-s3-images-policy` |
| 허용 Action | `s3:PutObject`, `s3:GetObject`, `s3:DeleteObject`, `s3:ListBucket` | 동일 |
| Resource | `billage-images-dev` 버킷 한정 | `billage-images-prod` 버킷 한정 |

### 4. IAM User (로컬 개발용)

| 속성 | Dev | Prod |
|------|-----|------|
| User Name | `billage-dev-s3-images-user` | `billage-prod-s3-images-user` |
| 용도 | 로컬 개발 시 Presigned URL 생성 | prod 접근이 필요한 경우 |
| Access Key | `terraform output iam_user_access_key_id` | 동일 명령 (s3-images-prod에서 실행) |
| Secret Key | `terraform output -raw iam_user_secret_access_key` | 동일 명령 (s3-images-prod에서 실행) |

### 5. IAM Role + Instance Profile (EC2 서버용)

| 속성 | Dev | Prod |
|------|-----|------|
| Role Name | `billage-dev-ec2-s3-images-role` | `billage-prod-ec2-s3-images-role` |
| Instance Profile | `billage-dev-ec2-s3-images-profile` | `billage-prod-ec2-s3-images-profile` |
| Trust Policy | ec2.amazonaws.com | ec2.amazonaws.com |

---

## Terraform 사용법

### Dev 적용

```bash
cd envs/s3-images-dev

terraform init      # 최초 1회
terraform plan      # 변경사항 확인
terraform apply     # 리소스 생성
```

### Prod 적용

```bash
cd envs/s3-images-prod

terraform init      # 최초 1회
terraform plan      # 변경사항 확인
terraform apply     # 리소스 생성
```

### Outputs 확인

```bash
# Dev
cd envs/s3-images-dev && terraform output

# Prod
cd envs/s3-images-prod && terraform output

# Secret Access Key 확인 (sensitive)
terraform output -raw iam_user_secret_access_key
```

### State 관리

| 환경 | State 버킷 | State Key | Lock Table |
|------|------------|-----------|------------|
| Dev | `billage-terraform-state-dev` | `s3-images/terraform.tfstate` | `billage-terraform-lock-dev` |
| Prod | `billage-terraform-state-prod` | `s3-images/terraform.tfstate` | `billage-terraform-lock-prod` |

> 각 환경의 EC2/VPC state key(`dev/terraform.tfstate`, `prod/terraform.tfstate`)와 충돌하지 않습니다.

---

## 백엔드 개발자 전달 사항

### 1. 로컬 개발 환경 설정

```bash
# 환경변수 설정 (.env 또는 shell)
AWS_ACCESS_KEY_ID=<terraform output 값>
AWS_SECRET_ACCESS_KEY=<terraform output -raw 값>
AWS_REGION=ap-northeast-2
```

### 2. Spring Boot 설정 예시 (application.yml)

```yaml
cloud:
  aws:
    s3:
      bucket: billage-images-${SPRING_PROFILES_ACTIVE}  # dev 또는 prod
    region:
      static: ap-northeast-2
    credentials:
      # 로컬: 환경변수에서 자동 로드
      # EC2: Instance Profile에서 자동 로드
      use-default-aws-credentials-chain: true
```

| Profile | 버킷명 |
|---------|--------|
| dev (로컬/Dev 서버) | `billage-images-dev` |
| prod (Prod 서버) | `billage-images-prod` |

### 3. Presigned URL 생성 흐름

```
[프론트엔드]                    [백엔드 API]                     [S3]
     │                              │                             │
     │  POST /api/images/upload     │                             │
     │  (파일명, Content-Type)      │                             │
     ├─────────────────────────────►│                             │
     │                              │  GeneratePresignedUrl(PUT)  │
     │                              ├────────────────────────────►│
     │                              │◄────────────────────────────┤
     │  200 { presignedUrl }        │                             │
     │◄─────────────────────────────┤                             │
     │                                                            │
     │  PUT presignedUrl (이미지 바이너리)                        │
     ├───────────────────────────────────────────────────────────►│
     │  200 OK                                                    │
     │◄───────────────────────────────────────────────────────────┤
```

---

## EC2 Instance Profile 연결

S3에 접근하려면 EC2 인스턴스에 IAM Role을 연결해야 합니다.

### 방법 1: AWS 콘솔 (즉시 적용)

1. EC2 콘솔 > 인스턴스 선택
2. Actions > Security > Modify IAM Role
3. 환경에 맞는 Instance Profile 선택:
   - Dev: `billage-dev-ec2-s3-images-profile`
   - Prod: `billage-prod-ec2-s3-images-profile`
4. Save

### 방법 2: Terraform (envs/dev/ 또는 envs/prod/ 수정)

`modules/ec2/variables.tf`에 변수 추가 후, `aws_instance` 리소스에 `iam_instance_profile` 속성을 설정합니다.

---

## 태깅 전략

모든 리소스에 일관된 태그가 적용됨:

| Tag | Value |
|-----|-------|
| Project | billage |
| Environment | dev / prod |
| ManagedBy | Terraform |

---

## 비용 예상 (월간)

| 리소스 | 예상 비용 |
|--------|-----------|
| S3 저장 (10GB 기준) | ~$0.25 |
| S3 요청 (PUT 10,000건) | ~$0.05 |
| S3 요청 (GET 100,000건) | ~$0.04 |
| 데이터 전송 (10GB) | ~$1.10 |
| **총 예상** | **~$1.5/월** |

> 500 MAU 기준 이미지 저장/조회량으로 추정한 비용입니다. S3는 사용량 기반 과금이므로 최소 비용으로 운영 가능합니다.

---

## 파일 구조

```
modules/s3-images/              # 재사용 가능한 모듈
├── main.tf                     # S3 버킷 + CORS + IAM User + IAM Role
├── variables.tf                # project_name, env, cors_allowed_origins, enable_versioning
└── outputs.tf                  # bucket_name, access_key, instance_profile 등

envs/s3-images-dev/             # dev 환경 S3 이미지
├── backend.tf                  # Provider + S3 backend (billage-terraform-state-dev)
├── main.tf                     # 모듈 호출
├── variables.tf                # 변수 정의
├── outputs.tf                  # 백엔드 개발자 전달 정보 출력
└── terraform.tfvars            # CORS: localhost:3000, dev.billages.com

envs/s3-images-prod/            # prod 환경 S3 이미지
├── backend.tf                  # Provider + S3 backend (billage-terraform-state-prod)
├── main.tf                     # 모듈 호출
├── variables.tf                # 변수 정의
├── outputs.tf                  # 백엔드 개발자 전달 정보 출력
└── terraform.tfvars            # CORS: www.billages.com, versioning 활성화
```