# Billage 시크릿 관리 전략 (V1 → V2 → V3)

> 이 문서는 서비스 성장 단계에 따른 시크릿 관리 전략의 진화를 다룬다.
> "현재에 맞는 선택"과 "미래를 위한 준비"의 균형점을 찾는 것이 목표다.

---

## 목차

1. [개요](#1-개요)
2. [시크릿 관리 도구 비교](#2-시크릿-관리-도구-비교)
3. [V1: SSM Parameter Store (현재)](#3-v1-ssm-parameter-store-현재)
4. [V2: AWS Secrets Manager 도입](#4-v2-aws-secrets-manager-도입)
5. [V3: HashiCorp Vault (벤더 독립)](#5-v3-hashicorp-vault-벤더-독립)
6. [전환 트리거 및 의사결정 프레임워크](#6-전환-트리거-및-의사결정-프레임워크)
7. [결론](#7-결론)

---

## 1. 개요

### 1.1 시크릿이란?

```
시크릿 = 노출되면 안 되는 민감한 정보

예시:
- 데이터베이스 비밀번호
- JWT 서명 키
- 외부 API 키 (OpenAI, Stripe 등)
- OAuth Client Secret
- TLS 인증서 개인키
```

### 1.2 시크릿 관리의 핵심 원칙

```
1. 코드에 시크릿을 넣지 않는다 (No Hardcoding)
2. 시크릿은 암호화된 상태로 저장한다 (Encryption at Rest)
3. 시크릿 접근은 감사 가능해야 한다 (Audit Trail)
4. 시크릿은 최소 권한으로 접근한다 (Least Privilege)
5. 시크릿은 주기적으로 교체한다 (Rotation)
```

### 1.3 우리의 현재 상황

```
서비스 단계: MVP / 초기 스타트업
인프라 구조: Single EC2 (Big Bang 배포)
DB: MySQL on EC2 (RDS 아님)
팀 규모: 5명 이하
시크릿 개수: 5~10개
예산: 제한적
클라우드: AWS 단일 (멀티 클라우드 계획 없음)
```

---

## 2. 시크릿 관리 도구 비교

### 2.1 주요 도구 개요

| 도구 | 유형 | 비용 | 벤더 종속 | 복잡도 |
|------|------|------|-----------|--------|
| 환경변수/.env | 파일 기반 | 무료 | 없음 | 낮음 |
| GitHub Secrets | CI/CD 전용 | 무료 | GitHub | 낮음 |
| SSM Parameter Store | 클라우드 관리형 | 무료 | AWS | 낮음 |
| AWS Secrets Manager | 클라우드 관리형 | 유료 | AWS | 중간 |
| HashiCorp Vault | 자체 운영 | 운영비 | 없음 | 높음 |
| Doppler/Infisical | SaaS | 유료 | 해당 SaaS | 중간 |

### 2.2 상세 비교

#### 환경변수 / .env 파일

```
장점:
+ 가장 단순함
+ 비용 없음
+ 모든 언어/프레임워크 지원

단점:
- 암호화 없음 (평문 저장)
- 버전 관리 없음
- 접근 감사 불가
- 팀 공유 어려움 (복사/붙여넣기)
- 실수로 Git 커밋 위험

적합한 상황:
→ 로컬 개발 환경
→ 절대 프로덕션에서 사용 금지
```

#### GitHub Secrets

```
장점:
+ 무료
+ GitHub Actions와 자연스러운 연동
+ 마스킹 처리 (로그에 노출 방지)
+ Organization 레벨 공유 가능

단점:
- CI/CD 전용 (런타임 접근 불가)
- 버전 관리 없음
- GitHub 의존성

적합한 상황:
→ CI/CD 파이프라인 전용 시크릿
→ Tailscale OAuth, AWS Role ARN 등
```

#### SSM Parameter Store (SecureString)

```
장점:
+ 무료 (Standard 파라미터)
+ KMS 암호화 지원
+ 버전 히스토리
+ IAM 기반 접근 제어
+ CloudTrail 감사 로그
+ 계층 구조 (/app/env/key)

단점:
- 자동 로테이션 없음 (Lambda 직접 구현 필요)
- AWS 종속
- 4KB 크기 제한 (Standard)

적합한 상황:
→ AWS 단일 클라우드
→ 시크릿 10~50개 수준
→ 자동 로테이션 불필요
→ 비용 최소화 필요
```

#### AWS Secrets Manager

```
장점:
+ RDS/Redshift/DocumentDB 자동 로테이션
+ 64KB 크기 제한
+ 크로스 리전 복제
+ 리소스 기반 정책

단점:
- 유료 ($0.40/시크릿/월 + API 호출 비용)
- AWS 종속
- EC2 내 DB는 자동 로테이션 불가

적합한 상황:
→ RDS 사용 시 (자동 로테이션 활용)
→ 멀티 리전 배포
→ 규정 준수 요구사항 (SOC2, HIPAA 등)
```

#### HashiCorp Vault

```
장점:
+ 벤더 독립 (멀티 클라우드)
+ Dynamic Secrets (필요시 생성, 자동 만료)
+ 다양한 인증 방식 (Kubernetes, OIDC, LDAP 등)
+ 암호화 as a Service
+ 풍부한 감사 로그
+ PKI, SSH 인증서 관리

단점:
- 운영 복잡성 (HA 구성, 백업, 업그레이드)
- 인프라 비용 (최소 3노드 HA)
- 학습 곡선
- 자체 장애 대응 필요

적합한 상황:
→ 멀티 클라우드 / 하이브리드 클라우드
→ 규정 준수 요구사항 (금융, 의료)
→ 대규모 시크릿 (100개 이상)
→ Dynamic Secrets 필요
→ 전담 인프라 팀 존재
```

### 2.3 비용 비교 (시크릿 10개 기준)

| 도구 | 월 비용 | 연 비용 |
|------|---------|---------|
| SSM Parameter Store | $0 | $0 |
| AWS Secrets Manager | $4 | $48 |
| Vault (Self-hosted, t3.small × 3) | ~$45 | ~$540 |
| Vault Cloud (HCP) | $0.03/시크릿/시간 | ~$2,600 |

---

## 3. V1: SSM Parameter Store (현재)

### 3.1 선택 근거

```
현재 상황:
- MySQL on EC2 → Secrets Manager 자동 로테이션 불가
- 시크릿 5~10개 → Vault는 오버스펙
- 예산 제한적 → 무료 솔루션 필요
- AWS 단일 클라우드 → 벤더 종속 문제 없음

결론: SSM Parameter Store (SecureString)가 최적
```

### 3.2 아키텍처

```
┌─────────────────────────────────────────────────────────────┐
│                    시크릿 관리 V1                            │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  [CI/CD 시크릿]                                              │
│  └─ GitHub Secrets                                           │
│      ├─ TAILSCALE_CLIENT_ID                                 │
│      ├─ TAILSCALE_CLIENT_SECRET                             │
│      └─ SSH_PRIVATE_KEY (백업용)                            │
│                                                              │
│  [애플리케이션 시크릿]                                        │
│  └─ SSM Parameter Store (SecureString)                      │
│      ├─ /billage/dev/db/host          (String)             │
│      ├─ /billage/dev/db/port          (String)             │
│      ├─ /billage/dev/db/name          (String)             │
│      ├─ /billage/dev/db/username      (SecureString) 🔐    │
│      ├─ /billage/dev/db/password      (SecureString) 🔐    │
│      ├─ /billage/dev/jwt/secret       (SecureString) 🔐    │
│      ├─ /billage/dev/jwt/expiration   (String)             │
│      └─ /billage/dev/openai/api-key   (SecureString) 🔐    │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

### 3.3 Terraform 구현

```hcl
# modules/secrets/main.tf

# KMS 키 (SecureString 암호화용)
resource "aws_kms_key" "secrets" {
  description             = "KMS key for SSM SecureString parameters"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  tags = {
    Name = "${var.project_name}-${var.env}-secrets-key"
  }
}

resource "aws_kms_alias" "secrets" {
  name          = "alias/${var.project_name}-${var.env}-secrets"
  target_key_id = aws_kms_key.secrets.key_id
}

# 일반 설정 (String)
resource "aws_ssm_parameter" "db_host" {
  name  = "/${var.project_name}/${var.env}/db/host"
  type  = "String"
  value = var.db_host

  tags = {
    Environment = var.env
    Type        = "config"
  }
}

# 민감한 시크릿 (SecureString)
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
    ignore_changes = [value]  # 수동 변경 허용
  }
}

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

# EC2 IAM Role에 SSM 읽기 권한 부여
resource "aws_iam_role_policy" "ssm_read" {
  name = "${var.project_name}-${var.env}-ssm-read"
  role = var.ec2_role_id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:GetParameters",
          "ssm:GetParametersByPath"
        ]
        Resource = "arn:aws:ssm:${var.region}:${var.account_id}:parameter/${var.project_name}/${var.env}/*"
      },
      {
        Effect = "Allow"
        Action = [
          "kms:Decrypt"
        ]
        Resource = aws_kms_key.secrets.arn
      }
    ]
  })
}
```

### 3.4 애플리케이션 연동

#### Spring Boot 예시

```java
// SecretsConfig.java
@Configuration
public class SecretsConfig {

    private final SsmClient ssmClient;

    public SecretsConfig() {
        this.ssmClient = SsmClient.builder()
            .region(Region.AP_NORTHEAST_2)
            .build();
    }

    @Bean
    public DataSource dataSource() {
        String host = getParameter("/billage/prod/db/host");
        String port = getParameter("/billage/prod/db/port");
        String dbName = getParameter("/billage/prod/db/name");
        String username = getParameter("/billage/prod/db/username");
        String password = getParameter("/billage/prod/db/password");  // SecureString 자동 복호화

        String url = String.format("jdbc:mysql://%s:%s/%s", host, port, dbName);

        return DataSourceBuilder.create()
            .url(url)
            .username(username)
            .password(password)
            .build();
    }

    @Bean
    public String jwtSecret() {
        return getParameter("/billage/prod/jwt/secret");
    }

    private String getParameter(String name) {
        GetParameterRequest request = GetParameterRequest.builder()
            .name(name)
            .withDecryption(true)  // SecureString 복호화
            .build();

        return ssmClient.getParameter(request).parameter().value();
    }
}
```

#### Spring Boot (환경변수 주입 방식)

```bash
#!/bin/bash
# /etc/profile.d/load-secrets.sh
# EC2 시작 시 실행

export DB_HOST=$(aws ssm get-parameter --name /billage/prod/db/host --query 'Parameter.Value' --output text)
export DB_PORT=$(aws ssm get-parameter --name /billage/prod/db/port --query 'Parameter.Value' --output text)
export DB_PASSWORD=$(aws ssm get-parameter --name /billage/prod/db/password --with-decryption --query 'Parameter.Value' --output text)
export JWT_SECRET=$(aws ssm get-parameter --name /billage/prod/jwt/secret --with-decryption --query 'Parameter.Value' --output text)
```

```yaml
# application.yml
spring:
  datasource:
    url: jdbc:mysql://${DB_HOST}:${DB_PORT}/billage
    username: ${DB_USERNAME}
    password: ${DB_PASSWORD}

jwt:
  secret: ${JWT_SECRET}
```

### 3.5 V1의 한계

```
1. 자동 로테이션 없음
   - DB 비밀번호 변경 시 수동 작업 필요
   - 애플리케이션 재시작 필요

2. 크로스 리전 복제 없음
   - DR 구성 시 별도 작업 필요

3. AWS 종속
   - 멀티 클라우드 전환 시 마이그레이션 필요

4. 4KB 크기 제한
   - 대용량 인증서 저장 불가
```

---

## 4. V2: AWS Secrets Manager 도입

### 4.1 전환 트리거

```
다음 조건 중 하나라도 해당되면 V2 전환 검토:

✅ RDS로 마이그레이션 예정
   → Secrets Manager 자동 로테이션 활용 가능

✅ 규정 준수 요구사항 발생 (SOC2, HIPAA 등)
   → 자동 로테이션 의무화

✅ 멀티 리전 배포 필요
   → 크로스 리전 복제 활용

✅ 시크릿 개수 50개 이상
   → 체계적인 관리 필요

✅ 전담 보안팀 구성
   → 보안 정책 고도화
```

### 4.2 하이브리드 아키텍처 (권장)

```
┌─────────────────────────────────────────────────────────────┐
│                    시크릿 관리 V2                            │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  [CI/CD 시크릿]                                              │
│  └─ GitHub Secrets (변경 없음)                               │
│                                                              │
│  [일반 설정값 - 비민감]                                       │
│  └─ SSM Parameter Store (String) - 무료 유지                │
│      ├─ /billage/prod/db/host                               │
│      ├─ /billage/prod/db/port                               │
│      ├─ /billage/prod/feature-flags/*                       │
│      └─ /billage/prod/config/*                              │
│                                                              │
│  [민감한 시크릿 - 자동 로테이션 대상]                          │
│  └─ AWS Secrets Manager                                      │
│      ├─ billage/prod/rds/credentials    ← 자동 로테이션     │
│      ├─ billage/prod/jwt/secret                             │
│      └─ billage/prod/external-api/*                         │
│                                                              │
└─────────────────────────────────────────────────────────────┘

비용 최적화:
- 설정값: SSM Parameter Store (무료)
- 시크릿: Secrets Manager ($0.40/개/월)
- 예상 비용: 시크릿 10개 = $4/월
```

### 4.3 Terraform 구현 (V2)

```hcl
# modules/secrets-v2/main.tf

# RDS 자동 로테이션용 시크릿
resource "aws_secretsmanager_secret" "rds_credentials" {
  name = "${var.project_name}/${var.env}/rds/credentials"

  tags = {
    Environment = var.env
    AutoRotate  = "true"
  }
}

resource "aws_secretsmanager_secret_version" "rds_credentials" {
  secret_id = aws_secretsmanager_secret.rds_credentials.id
  secret_string = jsonencode({
    username = var.db_username
    password = var.db_password
    engine   = "mysql"
    host     = aws_db_instance.main.address
    port     = 3306
    dbname   = var.db_name
  })
}

# RDS 자동 로테이션 설정
resource "aws_secretsmanager_secret_rotation" "rds_credentials" {
  secret_id           = aws_secretsmanager_secret.rds_credentials.id
  rotation_lambda_arn = aws_lambda_function.rotate_secret.arn

  rotation_rules {
    automatically_after_days = 30  # 30일마다 자동 로테이션
  }
}

# JWT Secret (수동 로테이션)
resource "aws_secretsmanager_secret" "jwt_secret" {
  name = "${var.project_name}/${var.env}/jwt/secret"

  tags = {
    Environment = var.env
    AutoRotate  = "false"
  }
}

# 일반 설정은 SSM Parameter Store 유지
resource "aws_ssm_parameter" "db_host" {
  name  = "/${var.project_name}/${var.env}/db/host"
  type  = "String"
  value = aws_db_instance.main.address
}
```

### 4.4 V2의 한계

```
1. AWS 종속 여전히 존재
   - 멀티 클라우드 시 각 클라우드별 시크릿 관리 필요

2. Dynamic Secrets 불가
   - 미리 저장된 시크릿만 사용
   - 필요시 생성 → 사용 → 자동 만료 패턴 불가

3. 비용 증가
   - 시크릿 수 증가에 따라 비용 선형 증가

4. 온프레미스 지원 없음
   - 하이브리드 클라우드 환경에서 불편
```

---

## 5. V3: HashiCorp Vault (벤더 독립)

### 5.1 전환 트리거

```
다음 조건 중 다수 해당되면 V3 전환 검토:

✅ 멀티 클라우드 운영 (AWS + GCP, AWS + Azure 등)
   → 통합 시크릿 관리 필요

✅ 온프레미스 + 클라우드 하이브리드
   → 단일 도구로 관리 필요

✅ Dynamic Secrets 필요
   → DB 접속마다 임시 자격증명 생성

✅ 금융/의료 등 강력한 규정 준수
   → 상세한 감사 로그, 정책 기반 접근 제어

✅ 시크릿 100개 이상
   → 대규모 관리 체계 필요

✅ 전담 인프라/보안팀 존재
   → Vault 운영 가능한 역량
```

### 5.2 Vault 아키텍처

```
┌─────────────────────────────────────────────────────────────┐
│                    시크릿 관리 V3                            │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│                    ┌─────────────────┐                      │
│                    │  HashiCorp Vault │                      │
│                    │    (HA Cluster)  │                      │
│                    └────────┬────────┘                      │
│                             │                                │
│         ┌───────────────────┼───────────────────┐           │
│         │                   │                   │           │
│         ▼                   ▼                   ▼           │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐     │
│  │     AWS     │    │     GCP     │    │ On-Premise  │     │
│  │  Workloads  │    │  Workloads  │    │  Workloads  │     │
│  └─────────────┘    └─────────────┘    └─────────────┘     │
│                                                              │
│  Secrets Engines:                                            │
│  ├─ KV v2 → Static secrets (JWT, API keys)                  │
│  ├─ Database → Dynamic DB credentials                       │
│  ├─ AWS → Dynamic AWS IAM credentials                       │
│  ├─ PKI → Dynamic TLS certificates                          │
│  └─ SSH → Dynamic SSH certificates                          │
│                                                              │
│  Auth Methods:                                               │
│  ├─ Kubernetes → Pod identity                               │
│  ├─ AWS IAM → EC2/Lambda identity                           │
│  ├─ OIDC → GitHub Actions, Human users                      │
│  └─ AppRole → Application identity                          │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

### 5.3 Vault의 핵심 가치: Dynamic Secrets

```
Static Secret (기존 방식):
┌─────────┐     ┌─────────┐     ┌─────────┐
│  App A  │────▶│ Secret  │◀────│  App B  │
│         │     │ (고정)  │     │         │
└─────────┘     └─────────┘     └─────────┘
                    │
        동일한 비밀번호를 여러 앱이 공유
        → 유출 시 전체 영향
        → 누가 사용했는지 추적 어려움


Dynamic Secret (Vault 방식):
┌─────────┐                         ┌─────────┐
│  App A  │──요청──▶┌────────┐◀──요청──│  App B  │
│         │        │ Vault  │        │         │
│         │◀─────  │        │  ─────▶│         │
│  user_a │ 임시   └────────┘  임시  │  user_b │
│  pw_xyz │ 발급              발급   │  pw_abc │
└─────────┘                         └─────────┘
     │                                   │
     ▼                                   ▼
  30분 후 자동 만료               30분 후 자동 만료

장점:
- 각 앱마다 고유한 자격증명
- 자동 만료로 유출 영향 최소화
- 누가 언제 사용했는지 완벽한 추적
```

### 5.4 Vault 구축 옵션

#### Option A: Self-hosted (Kubernetes)

```yaml
# vault-helm-values.yaml
server:
  ha:
    enabled: true
    replicas: 3
    raft:
      enabled: true

  resources:
    requests:
      memory: 256Mi
      cpu: 250m
    limits:
      memory: 512Mi
      cpu: 500m

  dataStorage:
    enabled: true
    size: 10Gi
    storageClass: gp3

ui:
  enabled: true

injector:
  enabled: true  # Sidecar injection for K8s pods
```

```bash
helm install vault hashicorp/vault -f vault-helm-values.yaml
```

**비용 추정 (AWS EKS)**
```
- EKS Cluster: $73/월
- EC2 (t3.medium × 3): ~$90/월
- EBS (10GB × 3): ~$3/월
- 총: ~$166/월
```

#### Option B: HCP Vault (관리형)

```
HashiCorp Cloud Platform Vault

장점:
- 운영 부담 제로
- 자동 업그레이드, 백업
- SLA 보장

단점:
- 비용 높음 ($0.03/시크릿/시간 = ~$22/시크릿/월)
- 시크릿 100개 = ~$2,200/월

적합한 상황:
→ 시크릿 수 적고, 운영 인력 없을 때
→ 우리 상황에서는 비현실적
```

#### Option C: Vault + SSM 하이브리드

```
Vault (멀티 클라우드 시크릿)
  ├─ Dynamic DB credentials
  ├─ PKI certificates
  └─ 크로스 클라우드 시크릿

SSM Parameter Store (AWS 전용 설정)
  ├─ Feature flags
  ├─ 환경별 설정값
  └─ 비민감 설정

장점:
- Vault 운영 부담 최소화
- AWS 네이티브 기능 활용
- 비용 최적화
```

### 5.5 V3의 Trade-offs

```
얻는 것:
+ 벤더 독립 (멀티 클라우드 대응)
+ Dynamic Secrets (보안 극대화)
+ 통합 시크릿 관리 (단일 도구)
+ 상세한 감사 로그
+ Policy as Code

잃는 것:
- 운영 복잡성 (HA 구성, 백업, 업그레이드, 모니터링)
- 인프라 비용 ($150~200/월)
- 학습 곡선 (팀 전체 교육 필요)
- 장애 대응 책임 (Vault 다운 = 전체 시크릿 접근 불가)

현실적 판단:
→ 우리 규모에서 Vault는 명확한 오버엔지니어링
→ 멀티 클라우드 계획이 없다면 AWS 네이티브 도구로 충분
```

---

## 6. 전환 트리거 및 의사결정 프레임워크

### 6.1 단계별 전환 트리거

```
┌─────────────────────────────────────────────────────────────┐
│                     V1 (SSM Parameter Store)                 │
│                                                              │
│  유지 조건:                                                   │
│  - AWS 단일 클라우드                                         │
│  - MySQL on EC2 (RDS 아님)                                   │
│  - 시크릿 50개 미만                                          │
│  - 자동 로테이션 불필요                                       │
│  - 팀 규모 10명 이하                                         │
│                                                              │
└──────────────────────────┬──────────────────────────────────┘
                           │
         ┌─────────────────┴─────────────────┐
         │         전환 트리거 (V1 → V2)       │
         │                                     │
         │  □ RDS로 DB 마이그레이션            │
         │  □ SOC2/HIPAA 등 규정 준수 필요     │
         │  □ 멀티 리전 배포                   │
         │  □ 시크릿 50개 이상                 │
         └─────────────────┬─────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────┐
│           V2 (SSM + AWS Secrets Manager 하이브리드)          │
│                                                              │
│  유지 조건:                                                   │
│  - AWS 단일 또는 AWS 중심 클라우드                           │
│  - 시크릿 100개 미만                                         │
│  - Static Secrets로 충분                                     │
│  - 전담 보안팀 없음                                          │
│                                                              │
└──────────────────────────┬──────────────────────────────────┘
                           │
         ┌─────────────────┴─────────────────┐
         │         전환 트리거 (V2 → V3)       │
         │                                     │
         │  □ 멀티 클라우드 운영               │
         │  □ 온프레미스 + 클라우드 하이브리드  │
         │  □ Dynamic Secrets 필요             │
         │  □ 금융/의료 규정 준수              │
         │  □ 시크릿 100개 이상                │
         │  □ 전담 인프라팀 구성               │
         └─────────────────┬─────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────┐
│                   V3 (HashiCorp Vault)                       │
│                                                              │
│  운영 요구사항:                                               │
│  - HA 클러스터 구성 (최소 3노드)                             │
│  - 24/7 모니터링                                             │
│  - 백업/복구 프로세스                                        │
│  - 업그레이드 전략                                           │
│  - 전담 운영 인력                                            │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

### 6.2 의사결정 플로우차트

```
시크릿 관리 도구 선택

                    시작
                      │
                      ▼
            ┌─────────────────┐
            │ 멀티 클라우드?   │
            └────────┬────────┘
                     │
         ┌───────────┴───────────┐
         │ Yes                   │ No
         ▼                       ▼
   ┌───────────┐         ┌─────────────────┐
   │   Vault   │         │ AWS 사용 중?     │
   └───────────┘         └────────┬────────┘
                                  │
                      ┌───────────┴───────────┐
                      │ Yes                   │ No
                      ▼                       ▼
              ┌─────────────────┐     ┌───────────────┐
              │ RDS 사용 중?     │     │ 해당 클라우드  │
              └────────┬────────┘     │ 네이티브 도구  │
                       │              └───────────────┘
           ┌───────────┴───────────┐
           │ Yes                   │ No
           ▼                       ▼
   ┌───────────────────┐   ┌─────────────────────┐
   │ Secrets Manager   │   │ SSM Parameter Store │
   │ (자동 로테이션)    │   │ (SecureString)      │
   └───────────────────┘   └─────────────────────┘
```

### 6.3 비용 대비 효과 분석

| 단계 | 월 비용 | 운영 복잡도 | 보안 수준 | 적합한 규모 |
|------|---------|-------------|-----------|-------------|
| V1 | $0 | ⭐ | ⭐⭐⭐ | 스타트업, MVP |
| V2 | $4~40 | ⭐⭐ | ⭐⭐⭐⭐ | 성장기, Series A-B |
| V3 | $150+ | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐⭐ | 엔터프라이즈 |

---

## 7. 결론

### 7.1 Billage 현재 권장 전략 (V1)

```
현재 상황:
- MVP 단계
- MySQL on EC2
- 시크릿 5~10개
- AWS 단일 클라우드
- 예산 제한적

권장 전략:
┌─────────────────────────────────────────────────────────────┐
│  GitHub Secrets                                              │
│  └─ CI/CD 전용 (Tailscale OAuth, SSH Key)                   │
│                                                              │
│  SSM Parameter Store (SecureString)                         │
│  └─ 모든 애플리케이션 시크릿                                 │
│      ├─ DB 자격증명                                         │
│      ├─ JWT Secret                                          │
│      └─ 외부 API 키                                         │
└─────────────────────────────────────────────────────────────┘

예상 비용: $0/월
```

### 7.2 마이그레이션 로드맵

```
현재 (2026 Q1)
└─ V1: SSM Parameter Store
    └─ 모든 시크릿 SSM SecureString으로 관리

DB 마이그레이션 시 (미정)
└─ V2: SSM + Secrets Manager 하이브리드
    └─ RDS 자격증명만 Secrets Manager로 이관
    └─ 나머지는 SSM 유지

멀티 클라우드 전환 시 (미정)
└─ V3: Vault 도입 검토
    └─ 전담 인프라팀 구성 후 결정
```

### 7.3 핵심 교훈

```
1. "현재 상황에 맞는 도구를 선택하라"
   - Vault가 좋다고 해서 MVP에 도입하면 오버엔지니어링
   - 성장에 따라 단계적으로 진화

2. "벤더 종속을 두려워하지 마라"
   - 멀티 클라우드 계획이 없다면 AWS 네이티브 도구로 충분
   - 벤더 종속 해결 비용 > 실제 이점인 경우가 많음

3. "무료 도구를 먼저 활용하라"
   - SSM Parameter Store SecureString은 무료지만 강력함
   - 유료 도구는 명확한 필요가 있을 때만

4. "마이그레이션 경로를 열어두라"
   - 코드에서 시크릿 접근 인터페이스 추상화
   - 나중에 도구 교체 시 영향 최소화
```

---

## 부록: 시크릿 관리 체크리스트

### 보안 체크리스트

- [ ] 코드에 하드코딩된 시크릿 없음
- [ ] .env 파일 .gitignore에 포함
- [ ] 모든 시크릿 암호화된 상태로 저장
- [ ] IAM 최소 권한 원칙 적용
- [ ] CloudTrail 감사 로그 활성화
- [ ] 시크릿 접근 가능한 인원 목록 관리
- [ ] 비상시 시크릿 로테이션 절차 문서화

### 운영 체크리스트

- [ ] 시크릿 목록 문서화 (값 제외)
- [ ] 시크릿 소유자/책임자 지정
- [ ] 로테이션 주기 정의
- [ ] 신규 시크릿 추가 프로세스 정의
- [ ] 퇴사자 발생 시 로테이션 절차

---

*문서 버전: 1.1*
*작성일: 2026-02-05*
*최종 수정일: 2026-02-09*
*작성자: Billage 인프라팀*
