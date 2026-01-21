# Billage Infrastructure (Terraform)

빌리지 인프라 코드 (Infrastructure as Code)

## 📁 디렉토리 구조

```
terraform/
├── modules/                    # 재사용 가능한 모듈
│   ├── vpc/                    # VPC, Subnet, IGW, Route Table
│   ├── ec2/                    # EC2 인스턴스
│   └── security-group/         # Security Group
├── envs/                       # 환경별 설정
│   └── dev/                    # 개발 환경
│       ├── backend.tf          # S3 Backend 설정
│       ├── main.tf             # 모듈 호출
│       ├── variables.tf        # 변수 정의
│       ├── outputs.tf          # 출력 정의
│       └── terraform.tfvars    # 변수 값 (gitignore)
└── .gitignore
```

## 🚀 시작하기

### 1. 사전 준비

#### AWS CLI 설정
```bash
aws configure
# AWS Access Key ID: <your-access-key>
# AWS Secret Access Key: <your-secret-key>
# Default region name: ap-northeast-2
# Default output format: json
```

#### AWS 키페어 생성 (AWS 콘솔에서)
1. EC2 > Key Pairs > Create key pair
2. 이름: `billage-dev-key`
3. Key pair type: RSA
4. Private key file format: .pem
5. 다운로드된 .pem 파일 안전하게 보관

### 2. 변수 파일 설정

```bash
cd envs/dev
cp terraform.tfvars.example terraform.tfvars
```

`terraform.tfvars` 수정:
```hcl
existing_key_name = "billage-keypair"  # 생성한 키페어 이름
```

### 3. Terraform 실행

```bash
# 초기화
terraform init

# 계획 확인
terraform plan

# 인프라 생성
terraform apply
```

### 4. 결과 확인

```bash
# 출력 확인
terraform output

# SSH 접속
ssh -i ~/billage-dev-key.pem ubuntu@<elastic_ip>
```

## 🔧 Backend 설정 (협업용)

팀 협업을 위해 S3 + DynamoDB Backend를 사용합니다.

### S3 버킷 & DynamoDB 테이블 생성

```bash
# S3 버킷 생성
aws s3 mb s3://billage-terraform-state-dev --region ap-northeast-2

# 버전 관리 활성화
aws s3api put-bucket-versioning \
  --bucket billage-terraform-state-dev \
  --versioning-configuration Status=Enabled

# DynamoDB 테이블 생성 (State Locking)
aws dynamodb create-table \
  --table-name billage-terraform-lock-dev \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region ap-northeast-2
```

### Backend 활성화

`backend.tf`에서 주석 해제:
```hcl
backend "s3" {
  bucket         = "billage-terraform-state-dev"
  key            = "dev/terraform.tfstate"
  region         = "ap-northeast-2"
  dynamodb_table = "billage-terraform-lock-dev"
  encrypt        = true
}
```

```bash
# Backend 마이그레이션
terraform init -migrate-state
```

## 📊 생성되는 리소스

| 리소스 | 이름 | 설명 |
|--------|------|------|
| VPC | billage-dev-vpc | 10.0.0.0/16 |
| Public Subnet | billage-dev-public-subnet | 10.0.1.0/24 |
| Internet Gateway | billage-dev-igw | - |
| Route Table | billage-dev-public-rt | 0.0.0.0/0 → IGW |
| Security Group | billage-dev-main-sg | SSH, HTTP, HTTPS, MySQL, etc. |
| EC2 | billage-dev-main-server | t4g.medium (ARM) |
| Elastic IP | billage-dev-eip | 고정 IP |

## 💰 예상 비용 (월)

| 리소스 | 비용 |
|--------|------|
| EC2 t4g.medium | ~34,000원 |
| EBS 20GB gp3 | ~2,000원 |
| Elastic IP | 무료 (사용 중일 때) |
| **합계** | **~36,000원** |

## 🔐 보안 권장사항

1. **SSH 접근 제한**: `ssh_allowed_cidr`를 개발자 IP로 제한
2. **DB 접근 제한**: 운영 시 `db_allowed_cidr`를 VPC CIDR로 제한
3. **키페어 관리**: .pem 파일은 절대 Git에 커밋하지 않음
4. **tfvars 관리**: `terraform.tfvars`는 .gitignore에 포함

## 🔄 협업 워크플로우 (GitHub Flow)

```
1. feature 브랜치 생성: feature/add-rds
2. 코드 작성 및 terraform plan 확인
3. PR 생성 → 코드 리뷰
4. main 머지 → terraform apply (수동 또는 CI/CD)
```

## 🗑️ 인프라 삭제

```bash
terraform destroy
```

## 📚 참고

- [Terraform AWS Provider](https://registry.terraform.io/providers/hashicorp/aws/latest)
- [AWS 서울 리전 가격](https://aws.amazon.com/ko/ec2/pricing/on-demand/)
- [Terraform Best Practices](https://www.terraform-best-practices.com/)
