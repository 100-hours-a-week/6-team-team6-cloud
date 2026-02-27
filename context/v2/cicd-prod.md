# v2 CI/CD 가이드 - Prod 환경

> 공통 가이드: [cicd.md](./cicd.md) | Dev 가이드: [cicd-dev.md](./cicd-dev.md)

## Prod 환경 요약

| 항목 | 값 |
|------|-----|
| 도메인 | `v2.billages.com` |
| VPC CIDR | `10.1.0.0/16` |
| ECR 태그 | `:prod-latest` |
| SSM 경로 | `/billage/prod/{service}/` |
| MinHealthyPercentage | `0` (초기), 스케일링 활성화 시 `50` 이상 권장 |
| ASG 인스턴스 수 | 각 서비스 1대 (초기, 나중에 조정) |

## 서비스별 정보

| 서비스 | ECR 이미지 태그 | ASG 이름 | Health Check |
|--------|---------------|----------|-------------|
| Backend | `billage-be:prod-latest` | `billage-prod-v2-be-asg` | `/actuator/health` |
| Frontend | `billage-fe:prod-latest` | `billage-prod-v2-fe-asg` | `/` |
| AI | `billage-ai:prod-latest` | `billage-prod-v2-ai-asg` | `/health` |

## GitHub Actions 워크플로우 (Backend 예시)

```yaml
name: Deploy Backend (Prod)

on:
  push:
    branches: [main]
    paths:
      - 'backend/**'

permissions:
  id-token: write   # OIDC 토큰 발급에 필요
  contents: read

env:
  AWS_REGION: ap-northeast-2
  ECR_REPOSITORY: billage-be
  ASG_NAME: billage-prod-v2-be-asg
  DEPLOY_ENV: prod

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Configure AWS credentials (OIDC)
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::988319239270:role/billage-github-actions-role
          aws-region: ${{ env.AWS_REGION }}

      - name: Login to ECR
        id: login-ecr
        uses: aws-actions/amazon-ecr-login@v2

      - name: Build & Push Docker image
        env:
          ECR_REGISTRY: ${{ steps.login-ecr.outputs.registry }}
        run: |
          docker build -t $ECR_REGISTRY/$ECR_REPOSITORY:$DEPLOY_ENV-latest \
                        -t $ECR_REGISTRY/$ECR_REPOSITORY:${{ github.sha }} .
          docker push $ECR_REGISTRY/$ECR_REPOSITORY:$DEPLOY_ENV-latest
          docker push $ECR_REGISTRY/$ECR_REPOSITORY:${{ github.sha }}

      - name: Trigger ASG Instance Refresh
        run: |
          aws autoscaling start-instance-refresh \
            --auto-scaling-group-name $ASG_NAME \
            --strategy Rolling \
            --preferences '{"MinHealthyPercentage": 0}'
```

### 주요 포인트

- **이미지 태그**: `prod-latest`와 `git sha` 두 개를 Push한다. `prod-latest`는 user_data에서 Pull용, `sha`는 롤백/추적용.
- **MinHealthyPercentage**: 초기에는 인스턴스 1대이므로 `0`으로 설정. ASG를 min=2 이상으로 스케일링하면 `50` 이상으로 변경해서 **무중단 배포**를 해야 한다.
- **트리거 브랜치**: `main` 브랜치 push 시 자동 배포.

### 스케일링 활성화 후 무중단 배포 설정

ASG min/max를 올린 후에는 워크플로우의 MinHealthyPercentage를 반드시 변경:

```yaml
      - name: Trigger ASG Instance Refresh
        run: |
          aws autoscaling start-instance-refresh \
            --auto-scaling-group-name $ASG_NAME \
            --strategy Rolling \
            --preferences '{"MinHealthyPercentage": 50}'
```

## SSM 파라미터

### 현재 등록 필요한 파라미터

**Backend (`/billage/prod/be/`)**

| SSM Key | 환경변수 | 타입 | 예시 |
|---------|---------|------|------|
| `spring-profiles-active` | SPRING_PROFILES_ACTIVE | String | `prod` |
| `spring-datasource-url` | SPRING_DATASOURCE_URL | String | `jdbc:mysql://billage-prod-v2-mysql.xxx.ap-northeast-2.rds.amazonaws.com:3306/billage` |
| `spring-datasource-username` | SPRING_DATASOURCE_USERNAME | String | `billage_admin` |
| `spring-datasource-password` | SPRING_DATASOURCE_PASSWORD | SecureString | (직접 입력) |
| `jwt-secret` | JWT_SECRET | SecureString | (직접 입력) |
| `rabbitmq-enabled` | RABBITMQ_ENABLED | String | `true` (자동 등록) |
| `rabbitmq-stomp-host` | RABBITMQ_STOMP_HOST | String | (자동 등록) |
| `rabbitmq-stomp-port` | RABBITMQ_STOMP_PORT | String | `61613` (자동 등록) |
| `rabbitmq-amqp-host` | RABBITMQ_AMQP_HOST | String | (자동 등록) |
| `rabbitmq-amqp-port` | RABBITMQ_AMQP_PORT | String | `5672` (자동 등록) |
| `rabbitmq-username` | RABBITMQ_USERNAME | String | `billage` (자동 등록) |
| `rabbitmq-password` | RABBITMQ_PASSWORD | SecureString | (자동 등록) |

**Frontend (`/billage/prod/fe/`)**

| SSM Key | 환경변수 | 타입 | 예시 |
|---------|---------|------|------|
| `node-env` | NODE_ENV | String | `production` |
| `next-public-api-url` | NEXT_PUBLIC_API_URL | String | `https://v2.billages.com/api` |
| `nextauth-secret` | NEXTAUTH_SECRET | SecureString | (직접 입력) |

**AI (`/billage/prod/ai/`)**

| SSM Key | 환경변수 | 타입 | 예시 |
|---------|---------|------|------|
| `env` | ENV | String | `prod` |

### 환경변수 관리

```bash
# 파라미터 추가
aws ssm put-parameter \
  --name "/billage/prod/be/new-variable" \
  --value "value" \
  --type String

# 파라미터 변경
aws ssm put-parameter \
  --name "/billage/prod/be/existing-variable" \
  --value "new-value" \
  --overwrite

# 전체 확인
aws ssm get-parameters-by-path \
  --path "/billage/prod/be/" \
  --with-decryption

# 변경 후 반드시 Instance Refresh 트리거
aws autoscaling start-instance-refresh \
  --auto-scaling-group-name billage-prod-v2-be-asg \
  --strategy Rolling \
  --preferences '{"MinHealthyPercentage": 0}'
```

## 네트워크 구조

```
Prod VPC (10.1.0.0/16)
├── Public Subnet (10.1.1.0/24, 10.1.2.0/24)
│   ├── ALB (v2.billages.com)
│   └── NAT Instance (t3.nano)
│
├── Private Subnet - EC2 (10.1.20.0/24, 10.1.21.0/24)
│   ├── BE EC2 → billage-be:prod-latest
│   ├── FE EC2 → billage-fe:prod-latest
│   └── AI EC2 → billage-ai:prod-latest
│   Route: 0.0.0.0/0 → NAT Instance
│
├── Private Subnet - RDS (10.1.12.0/24, 10.1.13.0/24)
│   └── RDS MySQL (billage-prod-v2-mysql)
│
└── Private Subnet - RabbitMQ (10.1.20.0/24)
    └── RabbitMQ (billage-prod-rabbitmq)
```

## Terraform 관리

### State Backend

| 리소스 | S3 Key |
|--------|--------|
| v2 Prod 인프라 | `v2/prod/terraform.tfstate` |
| Prod RDS | `shared/rds/prod/terraform.tfstate` |
| Prod RabbitMQ | `shared/rabbitmq/prod/terraform.tfstate` |

**Bucket**: `billage-terraform-state-prod`
**Lock Table**: `billage-terraform-lock-prod`

### 적용 순서

```
1. shared/rds/prod/       → terraform init && terraform apply
   (terraform.tfvars에 password 필요)

2. v2/envs/prod/          → terraform init && terraform apply
   (terraform.tfvars에 golden_ami_id 필요)
   (shared/rds/prod에서 RDS가 먼저 생성되어 있어야 함)

3. shared/rabbitmq/prod/  → terraform init && terraform apply
   (v1 prod와 v2 prod의 state outputs 참조 필요)
```

## 롤백

이전 버전으로 롤백하려면:

```bash
ECR_REGISTRY=988319239270.dkr.ecr.ap-northeast-2.amazonaws.com

# prod-latest 태그를 이전 sha로 재지정
MANIFEST=$(aws ecr batch-get-image \
  --repository-name billage-be \
  --image-ids imageTag=<이전-sha> \
  --query 'images[0].imageManifest' --output text)

aws ecr put-image \
  --repository-name billage-be \
  --image-tag prod-latest \
  --image-manifest "$MANIFEST"

# Instance Refresh 트리거
aws autoscaling start-instance-refresh \
  --auto-scaling-group-name billage-prod-v2-be-asg \
  --strategy Rolling \
  --preferences '{"MinHealthyPercentage": 0}'
```

## 디버깅

```bash
# 1. EC2 SSH 접속 (VPN 필요)
ssh -i billage-keypair.pem ubuntu@<private-ip>

# 2. user_data 실행 로그 확인
cat /var/log/user-data.log

# 3. 컨테이너 상태 확인
docker ps -a

# 4. 컨테이너 로그 확인
docker logs billage-backend

# 5. SSM 파라미터가 제대로 들어갔는지 확인
docker inspect billage-backend | grep -A 50 '"Env"'
```

## Prod 운영 주의사항

- Prod 배포 전에 **반드시 Dev에서 먼저 검증**한다.
- `main` 브랜치에 직접 push하지 말고 **PR을 통해 머지**한다.
- RDS `deletion_protection`은 초기에 `false`지만, 운영 시작 후 `true`로 변경 권장.
- ASG 스케일링 활성화 시 MinHealthyPercentage를 `50` 이상으로 변경해서 무중단 배포를 보장한다.
- SSM SecureString 파라미터(비밀번호, JWT 시크릿 등)는 **Dev와 다른 값**을 사용한다.