# Billage 시크릿 관리 전략

> 이 문서는 Billage 인프라의 시크릿 및 환경변수 관리 전략을 정의한다.
> 핵심 원칙: **애플리케이션 코드 변경 없이 환경변수로 주입**

---

## 목차

1. [개요](#1-개요)
2. [시크릿 저장소: SSM Parameter Store](#2-시크릿-저장소-ssm-parameter-store)
3. [v1-bigbang 시크릿 주입](#3-v1-bigbang-시크릿-주입)
4. [v2 시크릿 주입](#4-v2-시크릿-주입)
5. [Terraform 구현](#5-terraform-구현)
6. [운영 가이드](#6-운영-가이드)
7. [FAQ](#7-faq)
   ㅌㅂ
---

## 1. 개요

### 1.1 설계 원칙

```
1. 코드에 시크릿을 넣지 않는다 (No Hardcoding)
2. 애플리케이션 코드 변경 없이 환경변수로 주입
3. 중앙 집중식 관리 (SSM Parameter Store)
4. 환경별 분리 (/billage/dev/*, /billage/prod/*)
5. 비용 최적화 (무료 도구 우선)
```

### 1.2 아키텍처 결정

| 항목 | 결정 | 근거 |
|------|------|------|
| 저장소 | SSM Parameter Store | 무료, KMS 암호화 지원 |
| Secrets Manager | **사용 안함** | RDS 미사용으로 자동 로테이션 불필요 |
| 주입 방식 | 환경변수 | 앱 코드 변경 없음 |
| 암호화 | KMS (SecureString) | AWS 관리형 암호화 |

### 1.3 시크릿 흐름

```
┌─────────────────────────────────────────────────────────────────────┐
│                       시크릿 관리 흐름                               │
└─────────────────────────────────────────────────────────────────────┘

    Terraform                    EC2 Instance                  Container
        │                             │                            │
        │  aws_ssm_parameter          │                            │
        │  (SecureString)             │                            │
        ▼                             │                            │
┌───────────────┐                     │                            │
│ SSM Parameter │                     │                            │
│    Store      │                     │                            │
│               │    User Data        │                            │
│ /billage/dev/ │    (aws ssm        │                            │
│   db/password │     get-parameter)  │                            │
│   jwt/secret  │─────────────────────▶  .env 파일 생성            │
│   ...         │                     │       │                    │
└───────────────┘                     │       │  docker run        │
                                      │       │  --env-file .env   │
                                      │       ▼                    │
                                      │  ┌─────────────────────┐   │
                                      │  │ Container           │   │
                                      │  │ ENV: DB_PASSWORD=xx │   │
                                      │  │ ENV: JWT_SECRET=yy  │   │
                                      │  └─────────────────────┘   │
                                      │                            │
```

---

## 2. 시크릿 저장소: SSM Parameter Store

### 2.1 파라미터 구조

```
/billage/
├── dev/
│   ├── db/
│   │   ├── host              (String)        → localhost 또는 RDS 엔드포인트
│   │   ├── port              (String)        → 3306
│   │   ├── name              (String)        → billage
│   │   ├── username          (SecureString)  → billage_user
│   │   └── password          (SecureString)  → ********
│   │
│   ├── jwt/
│   │   ├── secret            (SecureString)  → jwt-signing-key-xxxxx
│   │   └── expiration        (String)        → 3600
│   │
│   ├── redis/
│   │   ├── host              (String)        → localhost 또는 ElastiCache
│   │   └── port              (String)        → 6379
│   │
│   └── external/
│       ├── openai-api-key    (SecureString)  → sk-xxxxxxxx
│       └── s3-bucket-name    (String)        → billage-images-dev
│
└── prod/
    └── (동일 구조)
```

### 2.2 파라미터 타입

| 타입 | 용도 | 암호화 | 비용 |
|------|------|--------|------|
| String | 비민감 설정 (host, port) | ❌ | 무료 |
| SecureString | 민감 시크릿 (password, api-key) | ✅ KMS | 무료 |

### 2.3 왜 Secrets Manager가 아닌가?

```
AWS Secrets Manager의 장점:
- RDS 자동 로테이션

우리 상황:
- v1: MySQL on EC2 → 자동 로테이션 불가
- v2: RDS 사용 예정이지만, 자동 로테이션 없이도 운영 가능
- 비용: $0.40/시크릿/월 × 10개 = $4/월 (불필요한 지출)

결론: SSM Parameter Store SecureString으로 충분
      (RDS 자동 로테이션 필요시 V2에서 재검토)
```

---

## 3. v1-bigbang 시크릿 주입

### 3.1 아키텍처

```
┌─────────────────────────────────────────────────────────────────────┐
│                    v1-bigbang 시크릿 주입                            │
└─────────────────────────────────────────────────────────────────────┘

┌──────────────┐    User Data     ┌──────────────┐    docker-compose
│ SSM Parameter│ ───────────────▶ │  .env 파일   │ ──────────────────▶
│    Store     │    스크립트      │              │      env_file
└──────────────┘                  └──────────────┘

                    EC2 Single Instance
                    ┌─────────────────────────────────────┐
                    │  /home/ubuntu/app/.env              │
                    │                                      │
                    │  ┌─────────────────────────────────┐│
                    │  │ docker-compose                  ││
                    │  │  ├── backend (env_file: .env)   ││
                    │  │  ├── frontend (env_file: .env)  ││
                    │  │  └── ai (env_file: .env)        ││
                    │  └─────────────────────────────────┘│
                    └─────────────────────────────────────┘
```

### 3.2 User Data 스크립트

```bash
#!/bin/bash
# v1-bigbang/envs/dev/user_data/load_secrets.sh

set -e

# ===== 설정 =====
PROJECT="billage"
ENV="dev"
REGION="ap-northeast-2"
APP_DIR="/home/ubuntu/app"

# ===== SSM 파라미터 조회 함수 =====
get_param() {
    aws ssm get-parameter \
        --name "/${PROJECT}/${ENV}/$1" \
        --with-decryption \
        --query 'Parameter.Value' \
        --output text \
        --region ${REGION}
}

# ===== SSM에서 시크릿 조회 =====
echo "[INFO] Fetching secrets from SSM Parameter Store..."

DB_HOST=$(get_param "db/host")
DB_PORT=$(get_param "db/port")
DB_NAME=$(get_param "db/name")
DB_USERNAME=$(get_param "db/username")
DB_PASSWORD=$(get_param "db/password")

JWT_SECRET=$(get_param "jwt/secret")
JWT_EXPIRATION=$(get_param "jwt/expiration")

REDIS_HOST=$(get_param "redis/host")
REDIS_PORT=$(get_param "redis/port")

OPENAI_API_KEY=$(get_param "external/openai-api-key")
S3_BUCKET_NAME=$(get_param "external/s3-bucket-name")

# ===== .env 파일 생성 =====
echo "[INFO] Creating .env file..."

mkdir -p ${APP_DIR}

cat > ${APP_DIR}/.env << EOF
# ===========================================
# Billage Environment Variables
# Generated by User Data script
# DO NOT EDIT MANUALLY
# ===========================================

# Database
DB_HOST=${DB_HOST}
DB_PORT=${DB_PORT}
DB_NAME=${DB_NAME}
DB_USERNAME=${DB_USERNAME}
DB_PASSWORD=${DB_PASSWORD}

# Spring Datasource (Spring Boot 호환)
SPRING_DATASOURCE_URL=jdbc:mysql://${DB_HOST}:${DB_PORT}/${DB_NAME}
SPRING_DATASOURCE_USERNAME=${DB_USERNAME}
SPRING_DATASOURCE_PASSWORD=${DB_PASSWORD}

# JWT
JWT_SECRET=${JWT_SECRET}
JWT_EXPIRATION=${JWT_EXPIRATION}

# Redis
REDIS_HOST=${REDIS_HOST}
REDIS_PORT=${REDIS_PORT}
SPRING_REDIS_HOST=${REDIS_HOST}
SPRING_REDIS_PORT=${REDIS_PORT}

# External APIs
OPENAI_API_KEY=${OPENAI_API_KEY}
S3_BUCKET_NAME=${S3_BUCKET_NAME}

# Environment
SPRING_PROFILES_ACTIVE=${ENV}
NODE_ENV=${ENV}
EOF

# 보안 설정
chmod 600 ${APP_DIR}/.env
chown ubuntu:ubuntu ${APP_DIR}/.env

echo "[INFO] Secrets loaded successfully!"
echo "[INFO] .env file created at ${APP_DIR}/.env"
```

### 3.3 docker-compose.yml

```yaml
# v1-bigbang 배포용 docker-compose.yml

version: '3.8'

services:
  backend:
    image: ghcr.io/100-hours-a-week/billage-backend:latest
    container_name: billage-backend
    env_file:
      - .env  # User Data에서 생성한 .env 파일
    ports:
      - "8080:8080"
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8080/actuator/health"]
      interval: 30s
      timeout: 10s
      retries: 3

  frontend:
    image: ghcr.io/100-hours-a-week/billage-frontend:latest
    container_name: billage-frontend
    env_file:
      - .env
    ports:
      - "3000:3000"
    restart: unless-stopped

  ai:
    image: ghcr.io/100-hours-a-week/billage-ai:latest
    container_name: billage-ai
    env_file:
      - .env
    ports:
      - "5000:5000"
    restart: unless-stopped
```

### 3.4 애플리케이션 설정 (코드 변경 없음)

**Spring Boot (application.yml)**
```yaml
# 환경변수를 자동으로 읽음 - 코드 변경 불필요
spring:
  datasource:
    url: ${SPRING_DATASOURCE_URL}
    username: ${SPRING_DATASOURCE_USERNAME}
    password: ${SPRING_DATASOURCE_PASSWORD}

  redis:
    host: ${SPRING_REDIS_HOST}
    port: ${SPRING_REDIS_PORT}

jwt:
  secret: ${JWT_SECRET}
  expiration: ${JWT_EXPIRATION}
```

**Next.js (.env 자동 로드)**
```javascript
// process.env.XXX로 자동 접근 - 코드 변경 불필요
const apiUrl = process.env.API_URL;
```

**FastAPI**
```python
# os.environ으로 자동 접근 - 코드 변경 불필요
import os
openai_key = os.environ.get("OPENAI_API_KEY")
```

---

## 4. v2 시크릿 주입

### 4.1 아키텍처

```
┌─────────────────────────────────────────────────────────────────────┐
│                       v2 시크릿 주입                                 │
└─────────────────────────────────────────────────────────────────────┘

                         Launch Template
                              │
                              │ User Data
                              ▼
┌──────────────┐         ┌─────────┐         ┌─────────────────────┐
│ SSM Parameter│ ──────▶ │   ASG   │ ──────▶ │  EC2 Instances      │
│    Store     │         │         │         │  ┌───────────────┐  │
└──────────────┘         └─────────┘         │  │ .env 파일     │  │
                                             │  │               │  │
                                             │  │ docker run    │  │
                                             │  │ --env-file    │  │
                                             │  └───────────────┘  │
                                             └─────────────────────┘
```

### 4.2 Launch Template User Data

```bash
#!/bin/bash
# v2/envs/dev/user_data/backend.sh

set -e

# ===== 설정 =====
PROJECT="billage"
ENV="dev"
REGION="ap-northeast-2"
APP_DIR="/home/ubuntu/app"
ECR_REGISTRY="123456789012.dkr.ecr.ap-northeast-2.amazonaws.com"
IMAGE_TAG="${IMAGE_TAG:-latest}"

# ===== SSM 파라미터 조회 함수 =====
get_param() {
    aws ssm get-parameter \
        --name "/${PROJECT}/${ENV}/$1" \
        --with-decryption \
        --query 'Parameter.Value' \
        --output text \
        --region ${REGION}
}

# ===== 시크릿 로드 =====
echo "[INFO] Loading secrets from SSM..."

DB_HOST=$(get_param "db/host")
DB_PORT=$(get_param "db/port")
DB_NAME=$(get_param "db/name")
DB_USERNAME=$(get_param "db/username")
DB_PASSWORD=$(get_param "db/password")
JWT_SECRET=$(get_param "jwt/secret")
REDIS_HOST=$(get_param "redis/host")
REDIS_PORT=$(get_param "redis/port")

# ===== .env 파일 생성 =====
mkdir -p ${APP_DIR}

cat > ${APP_DIR}/.env << EOF
SPRING_DATASOURCE_URL=jdbc:mysql://${DB_HOST}:${DB_PORT}/${DB_NAME}
SPRING_DATASOURCE_USERNAME=${DB_USERNAME}
SPRING_DATASOURCE_PASSWORD=${DB_PASSWORD}
JWT_SECRET=${JWT_SECRET}
SPRING_REDIS_HOST=${REDIS_HOST}
SPRING_REDIS_PORT=${REDIS_PORT}
SPRING_PROFILES_ACTIVE=${ENV}
EOF

chmod 600 ${APP_DIR}/.env

# ===== ECR 로그인 =====
aws ecr get-login-password --region ${REGION} | \
    docker login --username AWS --password-stdin ${ECR_REGISTRY}

# ===== Docker 컨테이너 실행 =====
docker pull ${ECR_REGISTRY}/billage-backend:${IMAGE_TAG}

docker stop billage-backend 2>/dev/null || true
docker rm billage-backend 2>/dev/null || true

docker run -d \
    --name billage-backend \
    --restart unless-stopped \
    --env-file ${APP_DIR}/.env \
    -p 8080:8080 \
    ${ECR_REGISTRY}/billage-backend:${IMAGE_TAG}

echo "[INFO] Backend started successfully!"
```

### 4.3 Terraform Launch Template

```hcl
# v2/modules/asg/main.tf

resource "aws_launch_template" "backend" {
  name_prefix   = "${var.project_name}-${var.env}-backend-"
  image_id      = data.aws_ami.ubuntu.id
  instance_type = var.instance_type

  iam_instance_profile {
    name = aws_iam_instance_profile.backend.name
  }

  user_data = base64encode(templatefile("${path.module}/user_data/backend.sh", {
    PROJECT      = var.project_name
    ENV          = var.env
    REGION       = var.region
    ECR_REGISTRY = var.ecr_registry
    IMAGE_TAG    = var.image_tag
  }))

  vpc_security_group_ids = [var.security_group_id]

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "${var.project_name}-${var.env}-backend"
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}
```

### 4.4 (대안) ECS 사용 시

ECS를 사용하면 Task Definition에서 SSM을 직접 참조할 수 있습니다:

```hcl
# v2/modules/ecs/task_definition.tf

resource "aws_ecs_task_definition" "backend" {
  family                   = "${var.project_name}-${var.env}-backend"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = 512
  memory                   = 1024
  execution_role_arn       = aws_iam_role.ecs_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([
    {
      name  = "backend"
      image = "${var.ecr_registry}/billage-backend:${var.image_tag}"

      # SSM Parameter Store 직접 참조 (SecureString)
      secrets = [
        {
          name      = "SPRING_DATASOURCE_PASSWORD"
          valueFrom = "arn:aws:ssm:${var.region}:${var.account_id}:parameter/${var.project_name}/${var.env}/db/password"
        },
        {
          name      = "JWT_SECRET"
          valueFrom = "arn:aws:ssm:${var.region}:${var.account_id}:parameter/${var.project_name}/${var.env}/jwt/secret"
        }
      ]

      # 일반 환경변수 (String)
      environment = [
        {
          name  = "SPRING_DATASOURCE_URL"
          value = "jdbc:mysql://${var.db_host}:3306/${var.db_name}"
        },
        {
          name  = "SPRING_PROFILES_ACTIVE"
          value = var.env
        }
      ]

      portMappings = [
        {
          containerPort = 8080
          protocol      = "tcp"
        }
      ]
    }
  ])
}
```

---

## 5. Terraform 구현

### 5.1 시크릿 모듈 구조

```
modules/secrets/
├── main.tf           # SSM Parameter 리소스
├── variables.tf      # 변수 정의
├── outputs.tf        # 출력 정의
└── iam.tf            # IAM 정책
```

### 5.2 main.tf

```hcl
# modules/secrets/main.tf

# ===== KMS Key =====
resource "aws_kms_key" "secrets" {
  description             = "KMS key for ${var.project_name}-${var.env} secrets"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  tags = {
    Name        = "${var.project_name}-${var.env}-secrets-key"
    Environment = var.env
  }
}

resource "aws_kms_alias" "secrets" {
  name          = "alias/${var.project_name}-${var.env}-secrets"
  target_key_id = aws_kms_key.secrets.key_id
}

# ===== Database Parameters =====
resource "aws_ssm_parameter" "db_host" {
  name  = "/${var.project_name}/${var.env}/db/host"
  type  = "String"
  value = var.db_host

  tags = {
    Environment = var.env
    Type        = "config"
  }
}

resource "aws_ssm_parameter" "db_port" {
  name  = "/${var.project_name}/${var.env}/db/port"
  type  = "String"
  value = var.db_port

  tags = {
    Environment = var.env
    Type        = "config"
  }
}

resource "aws_ssm_parameter" "db_name" {
  name  = "/${var.project_name}/${var.env}/db/name"
  type  = "String"
  value = var.db_name

  tags = {
    Environment = var.env
    Type        = "config"
  }
}

resource "aws_ssm_parameter" "db_username" {
  name   = "/${var.project_name}/${var.env}/db/username"
  type   = "SecureString"
  value  = var.db_username
  key_id = aws_kms_key.secrets.arn

  tags = {
    Environment = var.env
    Type        = "secret"
  }
}

resource "aws_ssm_parameter" "db_password" {
  name   = "/${var.project_name}/${var.env}/db/password"
  type   = "SecureString"
  value  = var.db_password
  key_id = aws_kms_key.secrets.arn

  tags = {
    Environment = var.env
    Type        = "secret"
  }

  lifecycle {
    ignore_changes = [value]  # 콘솔에서 수동 변경 허용
  }
}

# ===== JWT Parameters =====
resource "aws_ssm_parameter" "jwt_secret" {
  name   = "/${var.project_name}/${var.env}/jwt/secret"
  type   = "SecureString"
  value  = var.jwt_secret
  key_id = aws_kms_key.secrets.arn

  tags = {
    Environment = var.env
    Type        = "secret"
  }

  lifecycle {
    ignore_changes = [value]
  }
}

resource "aws_ssm_parameter" "jwt_expiration" {
  name  = "/${var.project_name}/${var.env}/jwt/expiration"
  type  = "String"
  value = var.jwt_expiration

  tags = {
    Environment = var.env
    Type        = "config"
  }
}

# ===== Redis Parameters =====
resource "aws_ssm_parameter" "redis_host" {
  name  = "/${var.project_name}/${var.env}/redis/host"
  type  = "String"
  value = var.redis_host

  tags = {
    Environment = var.env
    Type        = "config"
  }
}

resource "aws_ssm_parameter" "redis_port" {
  name  = "/${var.project_name}/${var.env}/redis/port"
  type  = "String"
  value = var.redis_port

  tags = {
    Environment = var.env
    Type        = "config"
  }
}

# ===== External API Keys =====
resource "aws_ssm_parameter" "openai_api_key" {
  count = var.openai_api_key != "" ? 1 : 0

  name   = "/${var.project_name}/${var.env}/external/openai-api-key"
  type   = "SecureString"
  value  = var.openai_api_key
  key_id = aws_kms_key.secrets.arn

  tags = {
    Environment = var.env
    Type        = "secret"
  }

  lifecycle {
    ignore_changes = [value]
  }
}
```

### 5.3 iam.tf

```hcl
# modules/secrets/iam.tf

# EC2가 SSM 파라미터를 읽을 수 있는 정책
resource "aws_iam_policy" "ssm_read" {
  name        = "${var.project_name}-${var.env}-ssm-read"
  description = "Allow reading SSM parameters for ${var.project_name}-${var.env}"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ReadSSMParameters"
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:GetParameters",
          "ssm:GetParametersByPath"
        ]
        Resource = [
          "arn:aws:ssm:${var.region}:${var.account_id}:parameter/${var.project_name}/${var.env}/*"
        ]
      },
      {
        Sid    = "DecryptKMS"
        Effect = "Allow"
        Action = [
          "kms:Decrypt"
        ]
        Resource = [
          aws_kms_key.secrets.arn
        ]
      }
    ]
  })
}

output "ssm_read_policy_arn" {
  description = "ARN of the SSM read policy"
  value       = aws_iam_policy.ssm_read.arn
}
```

### 5.4 variables.tf

```hcl
# modules/secrets/variables.tf

variable "project_name" {
  description = "Project name"
  type        = string
}

variable "env" {
  description = "Environment (dev/prod)"
  type        = string
}

variable "region" {
  description = "AWS region"
  type        = string
  default     = "ap-northeast-2"
}

variable "account_id" {
  description = "AWS account ID"
  type        = string
}

# Database
variable "db_host" {
  description = "Database host"
  type        = string
  default     = "localhost"
}

variable "db_port" {
  description = "Database port"
  type        = string
  default     = "3306"
}

variable "db_name" {
  description = "Database name"
  type        = string
  default     = "billage"
}

variable "db_username" {
  description = "Database username"
  type        = string
  sensitive   = true
}

variable "db_password" {
  description = "Database password"
  type        = string
  sensitive   = true
}

# JWT
variable "jwt_secret" {
  description = "JWT signing secret"
  type        = string
  sensitive   = true
}

variable "jwt_expiration" {
  description = "JWT expiration in seconds"
  type        = string
  default     = "3600"
}

# Redis
variable "redis_host" {
  description = "Redis host"
  type        = string
  default     = "localhost"
}

variable "redis_port" {
  description = "Redis port"
  type        = string
  default     = "6379"
}

# External APIs
variable "openai_api_key" {
  description = "OpenAI API key"
  type        = string
  default     = ""
  sensitive   = true
}
```

### 5.5 모듈 사용 예시

```hcl
# v1-bigbang/envs/dev/main.tf

module "secrets" {
  source = "../../../modules/secrets"

  project_name = var.project_name
  env          = var.env
  region       = var.region
  account_id   = data.aws_caller_identity.current.account_id

  # Database
  db_host     = "localhost"  # v1은 EC2 내부 MySQL
  db_port     = "3306"
  db_name     = "billage"
  db_username = var.db_username
  db_password = var.db_password

  # JWT
  jwt_secret     = var.jwt_secret
  jwt_expiration = "3600"

  # Redis
  redis_host = "localhost"
  redis_port = "6379"

  # External
  openai_api_key = var.openai_api_key
}

# EC2 Role에 SSM 읽기 권한 연결
resource "aws_iam_role_policy_attachment" "ec2_ssm" {
  role       = module.ec2.iam_role_name
  policy_arn = module.secrets.ssm_read_policy_arn
}
```

---

## 6. 운영 가이드

### 6.1 시크릿 조회

```bash
# 특정 파라미터 조회
aws ssm get-parameter \
    --name "/billage/dev/db/password" \
    --with-decryption \
    --query 'Parameter.Value' \
    --output text

# 환경별 전체 파라미터 조회
aws ssm get-parameters-by-path \
    --path "/billage/dev/" \
    --recursive \
    --with-decryption \
    --query 'Parameters[*].[Name,Value]' \
    --output table
```

### 6.2 시크릿 수동 변경

```bash
# AWS CLI로 변경
aws ssm put-parameter \
    --name "/billage/dev/db/password" \
    --value "new-password-here" \
    --type "SecureString" \
    --overwrite

# 변경 후 애플리케이션 재시작 필요
# v1: docker-compose restart
# v2: ASG Instance Refresh
```

### 6.3 시크릿 로테이션 절차

```
1. SSM Parameter Store에서 새 값으로 업데이트
   └─ aws ssm put-parameter --overwrite

2. 애플리케이션 재시작
   ├─ v1: docker-compose down && ./load_secrets.sh && docker-compose up -d
   └─ v2: ASG Instance Refresh 트리거

3. 기존 시크릿 무효화 확인
   └─ 로그에서 인증 실패 없는지 확인
```

### 6.4 신규 시크릿 추가 절차

```
1. modules/secrets/main.tf에 리소스 추가
2. modules/secrets/variables.tf에 변수 추가
3. envs/{env}/terraform.tfvars에 값 설정
4. terraform apply
5. User Data 스크립트에 조회 로직 추가
6. docker-compose.yml 또는 application.yml 업데이트
7. 배포
```

### 6.5 환경별 시크릿 분리

```
# dev 환경
/billage/dev/db/password → dev-password-123

# prod 환경
/billage/prod/db/password → prod-password-456-secure

# terraform.tfvars에서 환경별로 다른 값 설정
# dev/terraform.tfvars
db_password = "dev-password-123"

# prod/terraform.tfvars
db_password = "prod-password-456-secure"
```

---

## 7. FAQ

### Q1: 왜 Secrets Manager 대신 SSM Parameter Store?

```
A: 비용과 기능 면에서 현재 요구사항에 SSM이 적합합니다.

- Secrets Manager 자동 로테이션은 RDS에서만 의미 있음
- v1은 EC2 MySQL, v2도 초기에는 자동 로테이션 불필요
- 비용: SSM은 무료, Secrets Manager는 $0.40/시크릿/월

향후 RDS 자동 로테이션이 필요하면 그때 일부만 Secrets Manager로 이관
```

### Q2: 애플리케이션 코드 변경 없이 어떻게 시크릿을 읽나요?

```
A: 모든 주요 프레임워크는 환경변수를 자동으로 읽습니다.

- Spring Boot: ${ENV_VAR} 또는 application.yml에서 ${} 구문
- Next.js: process.env.ENV_VAR
- FastAPI/Python: os.environ.get("ENV_VAR")

User Data에서 .env 파일을 생성하고,
Docker가 --env-file로 컨테이너에 주입하면 끝!
```

### Q3: 시크릿이 변경되면 어떻게 반영하나요?

```
A: 현재는 수동 재배포가 필요합니다.

v1:
1. SSM에서 값 변경
2. EC2에서 load_secrets.sh 재실행
3. docker-compose restart

v2:
1. SSM에서 값 변경
2. ASG Instance Refresh 트리거
3. 새 인스턴스가 최신 시크릿으로 시작

자동 반영이 필요하면:
- Spring Cloud AWS 사용 (코드 변경 필요)
- 또는 주기적으로 시크릿 리로드하는 사이드카 구성
```

### Q4: 시크릿이 로그에 노출되지 않나요?

```
A: 주의가 필요합니다.

금지 사항:
- echo $DB_PASSWORD (로그에 남음)
- 애플리케이션에서 시크릿 로깅

권장 사항:
- set +x로 스크립트 디버그 출력 비활성화
- 애플리케이션 로그에서 시크릿 마스킹 처리
- CloudWatch Logs에 민감 정보 필터 설정
```

### Q5: 개발자가 프로덕션 시크릿에 접근할 수 있나요?

```
A: IAM으로 제어합니다.

권장 정책:
- Dev 개발자: /billage/dev/* 만 접근 가능
- DevOps: /billage/dev/*, /billage/prod/* 모두 접근 가능
- 프로덕션 시크릿 조회는 CloudTrail에 기록

IAM 정책 예시:
{
  "Effect": "Allow",
  "Action": ["ssm:GetParameter*"],
  "Resource": "arn:aws:ssm:*:*:parameter/billage/dev/*"
}
```

---

## 부록: 체크리스트

### 초기 설정 체크리스트

- [ ] KMS 키 생성 완료
- [ ] SSM Parameter Store에 모든 시크릿 등록
- [ ] EC2 IAM Role에 SSM 읽기 권한 부여
- [ ] User Data 스크립트에서 시크릿 로드 테스트
- [ ] docker-compose에서 env_file 설정 확인
- [ ] 애플리케이션에서 환경변수 정상 로드 확인

### 보안 체크리스트

- [ ] 코드에 하드코딩된 시크릿 없음
- [ ] .env 파일 .gitignore에 포함
- [ ] SecureString 사용 (민감 정보)
- [ ] IAM 최소 권한 원칙 적용
- [ ] CloudTrail 감사 로그 활성화
- [ ] 시크릿 접근 가능한 인원 목록 관리

---

*문서 버전: 2.0*
*최종 수정: 2026-02-09*
*작성자: Billage 인프라팀*
