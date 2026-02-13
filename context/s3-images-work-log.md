# S3 이미지 저장소 구축 작업 기록

## 배경

Billage 서비스에서 이미지를 저장할 S3 버킷이 필요했다. 백엔드(Spring Boot)에서 Presigned URL을 생성하고, 프론트엔드(Next.js)에서 해당 URL로 S3에 직접 업로드/다운로드하는 방식을 채택했다.

---

## 1. Presigned URL 방식에 필요한 설정 검토

Presigned URL로 이미지를 저장할 때 단순히 S3 버킷만 만들면 되는 게 아니라, 추가 설정이 필요했다.

### 필수 설정

- **CORS**: 브라우저에서 Presigned URL로 직접 S3에 요청하기 때문에, S3 버킷에 CORS 설정이 반드시 필요하다. 이걸 안 하면 브라우저가 요청을 차단한다.
- **Public Access 차단**: 버킷 자체를 퍼블릭으로 열 필요가 없다. Presigned URL이 임시 서명된 접근을 제공하므로, 퍼블릭 차단 상태를 유지하는 것이 보안상 맞다.
- **IAM 권한**: Presigned URL을 생성하는 주체(백엔드)에 `s3:PutObject`, `s3:GetObject`, `s3:DeleteObject` 권한이 필요하다.

### 인증 방식 결정

환경별로 인증 방식이 달라야 했다.

| 환경 | 인증 방식 | 이유 |
|------|-----------|------|
| 로컬 개발 | IAM User Access Key | EC2가 아니므로 Instance Profile 사용 불가 |
| EC2 서버 | IAM Instance Profile | Access Key 관리 불필요, 보안상 우수 |

AWS SDK(Spring Boot의 경우 AWS SDK for Java)는 **Default Credential Provider Chain**을 사용하기 때문에, 백엔드 코드 변경 없이 환경변수(로컬) 또는 Instance Profile(EC2)이 자동으로 적용된다.

**결론: IAM User(로컬용) + IAM Role/Instance Profile(EC2용) 둘 다 필요.**

---

## 2. 환경 분리 결정

S3 버킷을 환경별로 분리할지 하나로 공유할지 논의했다.

- **환경별 분리 채택**: `billage-images-dev`, `billage-images-prod`로 분리
  - 데이터 격리가 가능하고, dev에서 실수로 prod 데이터를 건드릴 위험이 없다
  - prod는 Versioning 활성화로 실수 삭제 방지

- **로컬 개발은 dev 버킷 공유**: 별도 버킷을 만들지 않고, IAM User Access Key로 dev 버킷에 접근한다.

---

## 3. Terraform 구조 설계

기존 `envs/dev/`에 S3 리소스를 추가하는 대신, **별도 폴더로 분리**해서 독립적으로 `terraform apply`할 수 있도록 설계했다.

### 이유

- dev 인프라(EC2/VPC)와 S3 인프라의 라이프사이클이 다르다
- S3만 따로 생성/삭제할 수 있어야 한다
- State 파일이 분리되어 서로 영향을 주지 않는다

### 구조

```
modules/s3-images/              # 재사용 가능한 모듈
├── main.tf                     # S3 버킷 + CORS + IAM User + IAM Role
├── variables.tf
└── outputs.tf

envs/s3-images-dev/             # dev용 (state: billage-terraform-state-dev)
├── backend.tf
├── main.tf
├── variables.tf
├── outputs.tf
└── terraform.tfvars

envs/s3-images-prod/            # prod용 (state: billage-terraform-state-prod)
├── backend.tf
├── main.tf
├── variables.tf
├── outputs.tf
└── terraform.tfvars
```

처음에는 `envs/s3-images/`라는 이름으로 만들었는데, dev/prod를 명확히 구분하기 위해 `envs/s3-images-dev/`, `envs/s3-images-prod/`로 변경했다.

---

## 4. 모듈 구현 내용

`modules/s3-images/main.tf`에서 생성하는 리소스 (총 12개):

| # | 리소스 | 설명 |
|---|--------|------|
| 1 | `aws_s3_bucket` | 이미지 저장 버킷 |
| 2 | `aws_s3_bucket_public_access_block` | 퍼블릭 접근 전체 차단 |
| 3 | `aws_s3_bucket_server_side_encryption_configuration` | AES-256 서버 사이드 암호화 |
| 4 | `aws_s3_bucket_versioning` | 버전 관리 (dev: Suspended, prod: Enabled) |
| 5 | `aws_s3_bucket_cors_configuration` | CORS 설정 |
| 6 | `aws_iam_policy` | S3 접근 권한 정책 (PutObject, GetObject, DeleteObject, ListBucket) |
| 7 | `aws_iam_user` | 로컬 개발용 IAM User |
| 8 | `aws_iam_user_policy_attachment` | User에 정책 연결 |
| 9 | `aws_iam_access_key` | User의 Access Key 발급 |
| 10 | `aws_iam_role` | EC2용 IAM Role (Trust: ec2.amazonaws.com) |
| 11 | `aws_iam_role_policy_attachment` | Role에 정책 연결 |
| 12 | `aws_iam_instance_profile` | EC2에 연결할 Instance Profile |

### Dev/Prod 차이점

모듈은 동일하게 재사용하고, `terraform.tfvars`의 값만 다르게 설정했다.

| 설정 | Dev | Prod |
|------|-----|------|
| env | `dev` | `prod` |
| CORS Origin | `http://localhost:3000`, `https://dev.billages.com` | `https://www.billages.com` |
| Versioning | `false` (Suspended) | `true` (Enabled) |
| State 버킷 | `billage-terraform-state-dev` | `billage-terraform-state-prod` |

---

## 5. 트러블슈팅

### IAM User 태그 Validation Error

**문제**: Dev 환경 `terraform apply` 시 IAM User 생성에서 에러 발생

```
Error: creating IAM User: ValidationError: 1 validation error detected:
Value at 'tags.2.member.value' failed to satisfy constraint:
Member must satisfy regular expression pattern: [\p{L}\p{Z}\p{N}_.:/=+\-@]*
```

**원인**: IAM 태그 값에 괄호 `()`를 사용했다. `Purpose = "S3 presigned URL 생성 (로컬 개발용)"` 에서 `(`와 `)`가 IAM 태그의 허용 문자 패턴에 포함되지 않았다.

**해결**: 태그 값을 영문으로 변경

```hcl
# Before
Purpose = "S3 presigned URL 생성 (로컬 개발용)"

# After
Purpose = "S3 presigned URL - local dev"
```

**참고**: IAM 태그는 `[\p{L}\p{Z}\p{N}_.:/=+\-@]*` 패턴만 허용한다. 유니코드 문자(한글)는 `\p{L}`에 해당되어 사용 가능하지만, 괄호는 허용되지 않는다.

이 에러는 12개 리소스 중 10개가 이미 생성된 후에 발생했기 때문에, 태그 수정 후 재적용 시 나머지 3개(IAM User, Access Key, Policy Attachment)만 추가 생성되었다.

---

## 6. 적용 결과

### Dev (envs/s3-images-dev)

```
Apply complete! Resources: 12 added, 0 changed, 0 destroyed.

Bucket Name       : billage-images-dev
Region            : ap-northeast-2
Access Key ID     : AKIA6MHDKZRTKV7M6L4Q
Instance Profile  : billage-dev-ec2-s3-images-profile
```

### Prod (envs/s3-images-prod)

```
Apply complete! Resources: 12 added, 0 changed, 0 destroyed.

Bucket Name       : billage-images-prod
Region            : ap-northeast-2
Access Key ID     : AKIA6MHDKZRTHPFBNYVH
Instance Profile  : billage-prod-ec2-s3-images-profile
```

---

## 7. 남은 작업

### EC2 Instance Profile 연결

현재 EC2 인스턴스에 IAM Role이 아직 연결되지 않은 상태다. 연결해야 EC2에서 Access Key 없이 S3에 접근할 수 있다.

**AWS 콘솔에서 연결하는 방법:**

1. EC2 콘솔 > 인스턴스 선택
2. Actions > Security > Modify IAM Role
3. Instance Profile 선택
   - Dev: `billage-dev-ec2-s3-images-profile`
   - Prod: `billage-prod-ec2-s3-images-profile`
4. Save

**IAM Instance Profile 확인 위치:**

AWS 콘솔에서 Instance Profile을 직접 목록으로 볼 수 있는 메뉴는 없다. 대신:
- **IAM > Roles** > Role 이름 검색 > 상세 페이지에서 Instance Profile ARN 확인
- **EC2 > Modify IAM Role** 드롭다운에서 목록 확인
- CLI: `aws iam list-instance-profiles`

### 백엔드 개발자에게 전달할 정보

```bash
# Dev Secret Key 확인
cd envs/s3-images-dev && terraform output -raw iam_user_secret_access_key

# Prod Secret Key 확인
cd envs/s3-images-prod && terraform output -raw iam_user_secret_access_key
```

백엔드 개발자에게 전달할 내용:
- S3 버킷명, 리전
- IAM User Access Key ID + Secret Access Key (로컬 개발용)
- Spring Boot application.yml 설정 예시 (`terraform output backend_developer_info`로 확인 가능)