# SSM Parameter Store 환경변수 관리 보고서

> 작성일: 2026-02-10
> 작성자: Billage 인프라팀
> 버전: 1.0

---

## 1. 개요

### 1.1 배경
기존 환경변수 관리 방식의 문제점:

| 방식 | 문제점 |
|------|--------|
| `.env` 파일 | 서버마다 수동 관리, 버전 관리 어려움 |
| GitHub Secrets | CI/CD에서만 접근 가능, 런타임 변경 불가 |
| 하드코딩 | 코드에 시크릿 노출, 환경별 분기 복잡 |

### 1.2 목표
- **중앙 집중 관리**: 모든 환경변수를 SSM Parameter Store에서 관리
- **환경 분리**: dev/prod 환경별 독립적인 설정
- **보안 강화**: SecureString으로 시크릿 암호화
- **접근 제어**: IAM 정책으로 세분화된 권한 관리
- **감사 추적**: CloudTrail로 파라미터 접근 기록

---

## 2. 파라미터 구조

### 2.1 네이밍 규칙

```
/{project}/{environment}/{service}/{key}

예시:
/billage/dev/be/jwt-secret
/billage/prod/fe/api-url
```

### 2.2 파라미터 맵

```
/billage/
├── dev/
│   ├── be/                          # Backend
│   │   ├── spring-profile           # String: dev
│   │   ├── cors-allowed             # String: *
│   │   ├── access-duration          # String: 7200000
│   │   ├── refresh-duration         # String: 604800000
│   │   ├── ai-base-url              # String: https://dev.billages.com/
│   │   ├── ai-timeout               # String: 10
│   │   ├── db-url                   # SecureString (Console 설정)
│   │   ├── db-username              # SecureString (Console 설정)
│   │   ├── db-password              # SecureString (Console 설정)
│   │   └── jwt-secret               # SecureString (Console 설정)
│   │
│   ├── fe/                          # Frontend
│   │   ├── api-url                  # String: https://api.dev.billages.com
│   │   ├── nextauth-url             # String: https://dev.billages.com
│   │   ├── nextauth-secret          # SecureString
│   │   ├── auth-trust-host          # String: true
│   │   └── image-hostname           # String: billage-images-dev.s3...
│   │
│   └── s3/                          # S3 Access
│       ├── bucket-name              # String: billage-images-dev
│       ├── region                   # String: ap-northeast-2
│       ├── access-key               # SecureString
│       └── secret-key               # SecureString
│
└── prod/
    ├── be/                          # (동일 구조)
    ├── fe/
    └── s3/
```

### 2.3 파라미터 타입

| 타입 | 용도 | 암호화 | 비용 |
|------|------|--------|------|
| `String` | 일반 설정값 (URL, 포트, 플래그) | X | 무료 |
| `SecureString` | 시크릿 (비밀번호, API 키, 토큰) | KMS | KMS API 호출 비용 |

---

## 3. 시크릿 목록

### 3.1 Backend (BE)

| 파라미터 | 설명 | 타입 |
|----------|------|------|
| `/billage/{env}/be/db-url` | DB 접속 URL | SecureString |
| `/billage/{env}/be/db-username` | DB 계정명 | SecureString |
| `/billage/{env}/be/db-password` | DB 비밀번호 | SecureString |
| `/billage/{env}/be/jwt-secret` | JWT 토큰 서명 키 | SecureString |

### 3.2 Frontend (FE)

| 파라미터 | 설명 | 타입 |
|----------|------|------|
| `/billage/{env}/fe/nextauth-secret` | NextAuth 세션 암호화 키 | SecureString |

### 3.3 S3 Access

| 파라미터 | 설명 | 타입 |
|----------|------|------|
| `/billage/{env}/s3/access-key` | S3 IAM Access Key | SecureString |
| `/billage/{env}/s3/secret-key` | S3 IAM Secret Key | SecureString |

> **권장사항**: S3 접근은 IAM Role (EC2 Instance Profile)로 대체하면 Access Key가 불필요해집니다.

---

## 4. 적용 방법

### 4.1 Terraform으로 파라미터 구조 생성

```bash
cd shared/ssm
terraform init
terraform apply
```

### 4.2 시크릿 값 설정

AWS Console에서 직접 설정:
1. AWS Console → Systems Manager → Parameter Store
2. 해당 SecureString 파라미터 선택
3. Edit → 실제 값 입력 → Save

### 4.3 파라미터 조회

```bash
# 단일 파라미터
aws ssm get-parameter --name "/billage/dev/be/db-url"

# 시크릿 (복호화)
aws ssm get-parameter --name "/billage/dev/be/db-password" --with-decryption

# 경로별 전체 조회
aws ssm get-parameters-by-path --path "/billage/dev/be" --with-decryption
```

---

## 5. 애플리케이션 통합

### 5.1 Spring Boot (Backend)

**build.gradle 의존성 추가:**
```groovy
implementation 'io.awspring.cloud:spring-cloud-aws-starter-parameter-store:3.1.0'
```

**application.yml:**
```yaml
spring:
  config:
    import: aws-parameterstore:/billage/${SPRING_PROFILES_ACTIVE}/be/
  cloud:
    aws:
      parameterstore:
        region: ap-northeast-2
```

**환경변수 매핑:**
```yaml
# SSM 파라미터가 자동으로 매핑됨
# /billage/dev/be/db-password → ${db-password}

spring:
  datasource:
    url: ${db-url}
    username: ${db-username}
    password: ${db-password}

jwt:
  secret: ${jwt-secret}
```

### 5.2 Next.js (Frontend)

**빌드 시점에 SSM에서 가져오기 (GitHub Actions):**
```yaml
- name: Get SSM Parameters
  run: |
    echo "NEXT_PUBLIC_API_URL=$(aws ssm get-parameter --name /billage/${{ env.ENV }}/fe/api-url --query 'Parameter.Value' --output text)" >> $GITHUB_ENV
    echo "NEXTAUTH_SECRET=$(aws ssm get-parameter --name /billage/${{ env.ENV }}/fe/nextauth-secret --with-decryption --query 'Parameter.Value' --output text)" >> $GITHUB_ENV
```

### 5.3 Docker Compose (런타임)

```yaml
services:
  backend:
    environment:
      - JWT_SECRET_KEY=${JWT_SECRET}
      - SPRING_DATASOURCE_PASSWORD=${DB_PASSWORD}
```

**entrypoint에서 SSM 조회:**
```bash
#!/bin/bash
export JWT_SECRET=$(aws ssm get-parameter --name /billage/${ENV}/be/jwt-secret --with-decryption --query 'Parameter.Value' --output text)
exec java -jar app.jar
```

---

## 6. IAM 권한

### 6.1 EC2 Instance Profile

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ssm:GetParameter",
        "ssm:GetParameters",
        "ssm:GetParametersByPath"
      ],
      "Resource": "arn:aws:ssm:ap-northeast-2:*:parameter/billage/${ENV}/*"
    },
    {
      "Effect": "Allow",
      "Action": "kms:Decrypt",
      "Resource": "arn:aws:kms:ap-northeast-2:*:key/*",
      "Condition": {
        "StringEquals": {
          "kms:ViaService": "ssm.ap-northeast-2.amazonaws.com"
        }
      }
    }
  ]
}
```

### 6.2 GitHub Actions (OIDC)

이미 `shared/oidc/`에서 SSM 읽기 권한 설정됨:
```hcl
resource "aws_iam_role_policy" "ssm_read" {
  # /billage/* 경로 읽기 권한
}
```

---

## 7. 보안 고려사항

### 7.1 암호화

- SecureString은 AWS 관리형 KMS 키(`aws/ssm`)로 암호화
- 커스텀 KMS 키 사용 시 키 로테이션 정책 적용 가능

### 7.2 접근 로깅

CloudTrail에서 SSM API 호출 기록:
- `GetParameter`
- `PutParameter`
- `GetParametersByPath`

### 7.3 최소 권한

- 환경별 분리: dev 서버는 `/billage/dev/*`만 접근
- 서비스별 분리: BE 서버는 `/billage/{env}/be/*`만 접근 (필요시)

---

## 8. 마이그레이션 체크리스트

### 8.1 적용 순서

- [ ] `terraform apply`로 SSM 파라미터 생성
- [ ] AWS Console에서 SecureString 시크릿 값 설정 (dev)
- [ ] AWS Console에서 SecureString 시크릿 값 설정 (prod)
- [ ] Backend Spring Boot 설정 변경
- [ ] Frontend 빌드 스크립트 변경
- [ ] EC2 IAM Role에 SSM 권한 추가
- [ ] 기존 `.env` 파일 제거
- [ ] GitHub Secrets에서 중복 시크릿 제거

### 8.2 롤백 계획

기존 `.env` 파일 백업 유지, 문제 발생 시 복원

---

## 9. 참고 자료

- [AWS SSM Parameter Store](https://docs.aws.amazon.com/systems-manager/latest/userguide/systems-manager-parameter-store.html)
- [Spring Cloud AWS Parameter Store](https://docs.awspring.io/spring-cloud-aws/docs/3.0.0/reference/html/index.html#parameter-store)
- [GitHub Actions에서 SSM 사용](https://github.com/aws-actions/aws-secretsmanager-get-secrets)

---

## 10. 변경 이력

| 버전 | 날짜 | 변경 내용 |
|------|------|----------|
| 1.0 | 2026-02-10 | 최초 작성 |