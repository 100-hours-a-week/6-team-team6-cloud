# Billage 보안 아키텍처 설계 의사결정 기록

> 이 문서는 Billage 프로젝트의 보안 아키텍처를 설계하면서 내린 기술적 의사결정과 그 근거를 기록한 것이다.

---

## 1. 배경: 실제 공격 로그에서 시작된 보안 재검토

### 1.1 발견된 공격 패턴

서비스 운영 중 Nginx 액세스 로그에서 다음과 같은 비정상 요청을 확인했다.

```log
216.81.245.109 - - [29/Jan/2026:00:19:36 +0900] "GET /.git/config HTTP/1.1" 404
98.88.247.68 - - [29/Jan/2026:00:29:31 +0900] "GET /?s=/Index/\x5Cthink\x5Capp/invokefunction&function=call_user_func_array&vars[0]=system&vars[1][]=printenv" 200
98.88.247.68 - - [29/Jan/2026:00:29:37 +0900] "GET /actuator/env HTTP/1.1" 404
```

**공격 유형 분석:**


| 요청                        | 공격 유형                     | 목적                                    |
| --------------------------- | ----------------------------- | --------------------------------------- |
| `/.git/config`              | 소스코드 탈취                 | Git 저장소 정보 획득 → 코드베이스 접근 |
| `/?s=/Index/\think\app/...` | ThinkPHP RCE (CVE-2018-20062) | 원격 코드 실행으로 환경변수 탈취        |
| `/actuator/env`             | Spring Boot Actuator 노출     | 애플리케이션 설정값/시크릿 탈취         |

추가로 `lsof -i :8080` 결과, 다수의 TCP 연결이 CLOSE_WAIT 상태로 잔존하는 것을 확인했다. 이는 HTTP Flood 공격의 전형적인 흔적이다.

### 1.2 현재 인프라의 보안 상태 점검

Terraform 코드 분석 결과, 다음 취약점이 확인되었다.

```hcl
# envs/prod/variables.tf
variable "ssh_allowed_cidr" {
  default = ["0.0.0.0/0"]  # SSH 전역 노출
}

# envs/dev/variables.tf
variable "db_allowed_cidr" {
  default = ["0.0.0.0/0"]  # MySQL 전역 노출
}
```

**취약점 요약:**


| 항목               | 현재 상태      | 위험도   | 영향                         |
| ------------------ | -------------- | -------- | ---------------------------- |
| SSH (22)           | 0.0.0.0/0      | Critical | 브루트포스, 무단 접근        |
| MySQL (3306)       | Dev: 0.0.0.0/0 | Critical | 데이터 유출                  |
| Spring Boot (8080) | 0.0.0.0/       | High     | Actuator 노출, API 직접 공격 |
| FastAPI (5000)     | 0.0.0.0/0      | High     | AI 서버 직접 접근            |

### 1.3 문제 정의

공격 로그와 인프라 분석을 통해 해결해야 할 문제를 정의했다.

```
P1: SSH/DB/애플리케이션 포트가 인터넷에 직접 노출되어 있다
P2: IP 기반 접근 제어는 관리가 불가능하다 (화이트리스트 지옥)
P3: CI/CD 파이프라인에서 장기 자격증명(Access Key, SSH Key)을 사용 중이다
P4: 시크릿이 체계적으로 관리되지 않는다
```

---

## 2. 접근 제어 방식 설계

### 2.1 IP 화이트리스트의 한계

첫 번째 시도는 SSH CIDR을 특정 IP로 제한하는 것이었다.

```hcl
ssh_allowed_cidr = ["123.456.789.0/32"]  # 개발자 IP
```

**실제 운영에서 발생한 문제:**

1. **개발자 IP 변동**: 재택, 카페, 출장 등 위치 변경 시 IP가 바뀜
2. **관리 복잡도 증가**: 팀원 N명 × 위치 M개 = N×M개의 IP 관리 필요
3. **GitHub Actions Runner**: 공용 Runner는 매 실행마다 IP가 다름

```
# 1주일 후 Security Group 상태
ssh_allowed_cidr = [
  "123.456.789.1/32",   # 개발자 A (집)
  "123.456.789.2/32",   # 개발자 A (카페) - 아직 유효?
  "111.222.333.4/32",   # 개발자 B (집)
  "222.333.444.5/32",   # 누구 IP?
  ...
]
```

**결론**: IP 기반 접근 제어는 소규모 팀에서도 관리 불가능. 다른 접근 방식 필요.

### 2.2 대안 비교: VPN vs Bastion Host

**Option A: Bastion Host (Jump Server)**

```
[개발자] → SSH → [Bastion] → SSH → [내부 서버]
```


| 장점                | 단점                                         |
| ------------------- | -------------------------------------------- |
| 구조가 단순         | SSH만 편리, 나머지는 터널링 필요             |
| SSH 접근 경로 명확  | DB 접근:`ssh -L 3306:localhost:3306 bastion` |
| 비용 저렴 (EC2 1대) | 모니터링 UI: 매번 터널링 설정                |

**Option B: VPN**

```
[개발자] → VPN 연결 → [VPC 내부 네트워크 전체 접근]
```


| 장점                           | 단점                         |
| ------------------------------ | ---------------------------- |
| 한 번 연결로 모든 리소스 접근  | VPN 솔루션 선택/관리 필요    |
| DB 클라이언트 직접 연결 가능   | 네트워크 전체 접근 권한 부여 |
| 모니터링 UI 브라우저 직접 접근 | 비용 발생 가능               |

**의사결정:**

현재 요구사항 분석:

- SSH 접근 필요 ✓
- MySQL Workbench로 DB 직접 접근 필요 ✓
- Grafana/Prometheus UI 브라우저 접근 필요 ✓

Bastion을 선택하면 SSH 외의 접근마다 터널링 설정이 필요하다. 개발 생산성을 고려하면 VPN이 적합하다.

**선택: VPN**

---

## 3. VPN 솔루션 선택

### 3.1 요구사항 정의

```
R1: 빠른 도입 (1주일 내 적용)
R2: 비용 최소화 (사이드 프로젝트, 수익 없음)
R3: GitHub Actions 연동 가능
R4: 팀원 온보딩 용이
```

### 3.2 솔루션 비교


| 솔루션         | 도입 시간 | 월 비용        | GH Actions  | 관리 부담       |
| -------------- | --------- | -------------- | ----------- | --------------- |
| AWS Client VPN | 1-2일     | $72+           | 복잡        | 낮음 (관리형)   |
| OpenVPN        | 3-5일     | 무료           | 수동 설정   | 높음 (PKI 필요) |
| WireGuard      | 2-3일     | 무료           | 수동 설정   | 중간            |
| Tailscale      | 30분      | 무료 (100기기) | 공식 Action | 낮음            |

### 3.3 각 솔루션 분석

**AWS Client VPN**

```
+ AWS 관리형, 고가용성
+ IAM/AD 연동 가능
- 비용: $0.10/시간 × 24 × 30 = $72/월 (최소)
- 현재 예산 상황에서 부담
```

**OpenVPN**

```
+ 검증된 안정성, 널리 사용됨
- PKI 인프라 구축 필요 (CA, 서버/클라이언트 인증서)
- easy-rsa 설정, 인증서 배포 프로세스 필요
- 도입까지 3-5일 예상
```

**WireGuard**

```
+ 커널 레벨 구현, 최고 성능
+ 코드베이스 4,000줄 (OpenVPN 대비 보안 감사 용이)
- 피어 설정, 키 교환 직접 관리
- 동적 IP 환경에서 추가 구성 필요
```

**Tailscale**

```
+ WireGuard 기반, 복잡한 설정 추상화
+ 설치: curl -fsSL https://tailscale.com/install.sh | sh && tailscale up
+ GitHub Actions 공식 지원 (tailscale/github-action)
+ NAT traversal 자동 처리
- Tailscale SaaS 의존성 (메타데이터가 Tailscale 서버 경유)
- Tailscale 서비스 장애 시 새 연결 불가
```

### 3.4 의사결정

**요구사항 대비 평가:**


| 요구사항       | AWS Client VPN | OpenVPN    | WireGuard  | Tailscale  |
| -------------- | -------------- | ---------- | ---------- | ---------- |
| R1: 빠른 도입  | ⭐⭐⭐         | ⭐         | ⭐⭐       | ⭐⭐⭐⭐⭐ |
| R2: 비용       | ⭐             | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐⭐ |
| R3: GH Actions | ⭐⭐           | ⭐⭐       | ⭐⭐       | ⭐⭐⭐⭐⭐ |
| R4: 온보딩     | ⭐⭐⭐         | ⭐⭐       | ⭐⭐       | ⭐⭐⭐⭐⭐ |

**선택: Tailscale**

**Trade-off 인식:**

- Tailscale SaaS 의존성은 인지하고 있음
- 이를 보완하기 위해 SSM을 백업 접근 경로로 구성 (섹션 4 참조)
- 추후 Private Subnet 도입 시 AWS Client VPN 재검토 예정

### 3.5 구현

**서버 설정:**

```bash
# EC2 인스턴스
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up --advertise-tags=tag:server --hostname=billage-main
```

**Security Group 수정:**

```hcl
variable "tailscale_cidr" {
  description = "Tailscale CGNAT 대역"
  default     = "100.64.0.0/10"
}

# SSH - Tailscale에서만 허용
ingress {
  description = "SSH from Tailscale"
  from_port   = 22
  to_port     = 22
  protocol    = "tcp"
  cidr_blocks = [var.tailscale_cidr]
}

# MySQL - Tailscale에서만 허용
ingress {
  description = "MySQL from Tailscale"
  from_port   = 3306
  to_port     = 3306
  protocol    = "tcp"
  cidr_blocks = [var.tailscale_cidr]
}
```

---

## 4. 장애 대비: 백업 접근 경로

### 4.1 SPOF(Single Point of Failure) 분석

Tailscale 도입 후 모든 관리 접근이 Tailscale을 경유한다.

```
Tailscale 장애 시나리오:
- Tailscale 서비스 다운 → 새 VPN 연결 불가
- 기존 연결도 일정 시간 후 끊김
- SSH, DB, 모니터링 모두 접근 불가
- 서비스 장애 발생해도 대응 불가
```

**문제**: Tailscale이 SPOF가 됨

### 4.2 백업 경로: AWS SSM Session Manager

SSM Session Manager는 SSH 없이 EC2에 접근할 수 있게 해준다.

**동작 원리:**

```
[관리자] → AWS API → [SSM Service] → [SSM Agent on EC2] → Shell
```

**장점:**

- SSH 포트(22) 불필요
- IAM으로 접근 제어
- 모든 세션이 CloudTrail에 기록됨

**구현:**

```hcl
# EC2 IAM Role에 SSM 정책 추가
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}
```

**사용:**

```bash
# Tailscale 장애 시
aws ssm start-session --target i-1234567890abcdef0
```

### 4.3 접근 경로 정리


| 상황           | 접근 방식           | 비고          |
| -------------- | ------------------- | ------------- |
| 정상           | Tailscale → SSH    | 일상적인 작업 |
| Tailscale 장애 | SSM Session Manager | 긴급 대응     |
| AWS 장애       | (대응 불가)         | AWS 복구 대기 |

---

## 5. CI/CD 파이프라인 보안

### 5.1 현재 상태의 문제점

```yaml
# 기존 GitHub Actions
- name: Configure AWS
  uses: aws-actions/configure-aws-credentials@v4
  with:
    aws-access-key-id: ${{ secrets.AWS_ACCESS_KEY_ID }}
    aws-secret-access-key: ${{ secrets.AWS_SECRET_ACCESS_KEY }}

- name: Deploy
  run: |
    ssh -i ${{ secrets.SSH_PRIVATE_KEY }} ubuntu@${{ secrets.SERVER_IP }} "..."
```

**문제점:**

1. AWS Access Key: 장기 자격증명, rotate하지 않으면 영구 유효
2. SSH Private Key: 유출 시 서버 직접 접근 가능
3. Server IP: 고정 IP가 secrets에 하드코딩

### 5.2 배포 방식 비교


| 방식               | 장점                  | 단점                  | 적합한 상황       |
| ------------------ | --------------------- | --------------------- | ----------------- |
| SSH 직접           | 간단, 직관적          | IP 화이트리스트 문제  | -                 |
| Tailscale + SSH    | IP 문제 해결, 무료    | Tailscale 의존        | 소규모, 빠른 도입 |
| SSM Run Command    | SSH 불필요, 감사 로그 | 실시간 출력 어려움    | 간단한 명령       |
| Self-hosted Runner | 네트워크 제약 없음    | EC2 비용, 관리 필요   | 빌드 집약적       |
| CodeDeploy         | 롤백, 배포 전략       | 설정 복잡, Agent 필요 | 다중 인스턴스     |

### 5.3 의사결정

**현재 상황:**

- 인스턴스: 1개
- 배포 명령: `docker-compose pull && up`
- 배포 빈도: 1일 1-2회

**분석:**

- CodeDeploy: 오버스펙 (Blue/Green이 필요한 규모가 아님)
- Self-hosted Runner: EC2 비용 대비 효과 불명확
- SSM Run Command: 간단한 배포에 적합하지만 Tailscale로 충분
- Tailscale + SSH: 현재 규모에 가장 적합

**선택:**

- 메인: Tailscale + SSH (간단, 무료)
- 백업: SSM Run Command (Tailscale 장애 시)

### 5.4 구현: AWS 인증을 OIDC로 전환

장기 자격증명(Access Key)을 제거하고 OIDC로 전환한다.

**OIDC 동작 원리:**

```
1. GitHub Actions가 OIDC 토큰 요청
2. GitHub이 토큰 발급 (repo, branch 정보 포함)
3. AWS STS가 토큰 검증
4. 검증 성공 시 임시 자격증명 발급 (1시간 유효)
```

**Terraform 구성:**

```hcl
# OIDC Provider
resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

# IAM Role
resource "aws_iam_role" "github_actions" {
  name = "github-actions-deploy"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = aws_iam_openid_connect_provider.github.arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        StringLike = {
          # 특정 리포지토리의 main 브랜치만 허용
          "token.actions.githubusercontent.com:sub" = "repo:our-org/our-repo:ref:refs/heads/main"
        }
      }
    }]
  })
}
```

**GitHub Actions:**

```yaml
jobs:
  deploy:
    runs-on: ubuntu-latest
    permissions:
      id-token: write
      contents: read

    steps:
      - name: Configure AWS (OIDC)
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::123456789:role/github-actions-deploy
          aws-region: ap-northeast-2
          # Access Key가 필요 없음

      - name: Setup Tailscale
        uses: tailscale/github-action@v2
        with:
          oauth-client-id: ${{ secrets.TAILSCALE_CLIENT_ID }}
          oauth-secret: ${{ secrets.TAILSCALE_CLIENT_SECRET }}
          tags: tag:ci

      - name: Deploy
        run: ssh ubuntu@billage-main "cd /app && docker-compose pull && docker-compose up -d"
```

**개선 효과:**


| 항목        | Before             | After             |
| ----------- | ------------------ | ----------------- |
| AWS 인증    | 장기 Access Key    | 임시 토큰 (1시간) |
| 권한 범위   | IAM User 전체 권한 | Role의 최소 권한  |
| 브랜치 제한 | 없음               | main만 허용 가능  |
| 키 rotate   | 수동               | 불필요            |

---

## 6. 시크릿 관리 전략

### 6.1 관리해야 할 시크릿 분류


| 시크릿          | 사용처              | 민감도 | 변경 빈도 |
| --------------- | ------------------- | ------ | --------- |
| DB 비밀번호     | 애플리케이션 런타임 | 높음   | 낮음      |
| JWT Secret      | 애플리케이션 런타임 | 높음   | 낮음      |
| 외부 API 키     | 애플리케이션 런타임 | 높음   | 낮음      |
| DB 호스트       | 애플리케이션 런타임 | 낮음   | 매우 낮음 |
| Tailscale OAuth | CI/CD               | 중간   | 낮음      |
| AWS Role ARN    | CI/CD               | 낮음   | 매우 낮음 |

### 6.2 저장소 옵션 비교


| 저장소              | 비용            | 자동 로테이션 | 버전 관리 | 접근 방식  |
| ------------------- | --------------- | ------------- | --------- | ---------- |
| 환경변수/.env       | 무료            | ❌            | ❌        | 파일 읽기  |
| GitHub Secrets      | 무료            | ❌            | ❌        | CI/CD 주입 |
| SSM Parameter Store | 무료/저렴       | ❌            | ✅        | AWS SDK    |
| Secrets Manager     | $0.40/시크릿/월 | ✅            | ✅        | AWS SDK    |

### 6.3 의사결정: 하이브리드 접근

모든 시크릿을 한 곳에 저장하는 것은 비효율적이다. 용도와 민감도에 따라 분리한다.

```
┌─────────────────────────────────────────────────────────────┐
│                     시크릿 관리 아키텍처                       │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  [CI/CD 전용]                                                │
│  └─ GitHub Secrets                                           │
│      ├─ TAILSCALE_CLIENT_ID (Tailscale OAuth)               │
│      ├─ TAILSCALE_CLIENT_SECRET                              │
│      └─ AWS_ROLE_ARN (OIDC용, 민감하지 않음)                 │
│                                                              │
│  [애플리케이션 설정 - 민감하지 않음]                           │
│  └─ SSM Parameter Store (무료)                               │
│      ├─ /billage/prod/db/host                                │
│      ├─ /billage/prod/db/port                                │
│      └─ /billage/prod/feature-flags/*                        │
│                                                              │
│  [민감한 시크릿]                                              │
│  └─ AWS Secrets Manager                                      │
│      ├─ billage/prod/db/credentials                          │
│      ├─ billage/prod/jwt-secret                              │
│      └─ billage/prod/external-api-keys                       │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

**선택 근거:**

- GitHub Secrets: CI/CD에서만 필요, 런타임 접근 불필요
- SSM Parameter Store: 무료, 설정값에 적합
- Secrets Manager: 유료지만 자동 로테이션 필요한 민감 정보에 적합

### 6.4 구현: 런타임 시크릿 주입

애플리케이션이 시작할 때 AWS SDK로 시크릿을 가져온다.

**Spring Boot 예시:**

```java
@Configuration
public class SecretsConfig {

    private final SecretsManagerClient secretsManager;
    private final SsmClient ssm;

    @Bean
    public DataSource dataSource() {
        // SSM에서 호스트 정보
        String host = getParameter("/billage/prod/db/host");
        String port = getParameter("/billage/prod/db/port");

        // Secrets Manager에서 인증 정보
        JsonObject credentials = getSecret("billage/prod/db/credentials");

        return DataSourceBuilder.create()
            .url("jdbc:mysql://" + host + ":" + port + "/billage")
            .username(credentials.get("username").getAsString())
            .password(credentials.get("password").getAsString())
            .build();
    }

    private String getParameter(String name) {
        return ssm.getParameter(r -> r.name(name)).parameter().value();
    }

    private JsonObject getSecret(String secretId) {
        String json = secretsManager.getSecretValue(r -> r.secretId(secretId)).secretString();
        return JsonParser.parseString(json).getAsJsonObject();
    }
}
```

**장점:**

- 시크릿이 환경변수나 파일에 남지 않음
- 시크릿 변경 시 재배포 없이 반영 가능 (애플리케이션 재시작만)
- IAM으로 세밀한 접근 제어

---

## 7. 단계적 구현 계획

### 7.1 현재 인프라 상태

```
- 아키텍처: Public Subnet, Single Instance (Big Bang 배포)
- 팀 규모: 5명 이하
- 예산: 제한적
- 상태: MVP 단계
```

### 7.2 Phase 1: 즉시 적용 (1-2주)

**목표**: 가장 위험한 취약점 제거


| 작업                | 목적               | 우선순위 |
| ------------------- | ------------------ | -------- |
| Tailscale 도입      | SSH/DB 포트 보호   | P0       |
| Security Group 수정 | 접근 제어 적용     | P0       |
| OIDC 전환           | 장기 자격증명 제거 | P0       |
| SSM 백업 경로       | 장애 대비          | P1       |

### 7.3 Phase 2: 단기 개선 (1-2개월)

**목표**: 체계적인 보안 관리 기반 구축


| 작업                     | 목적                            |
| ------------------------ | ------------------------------- |
| 애플리케이션 포트 내부화 | 8080, 3000, 5000 외부 노출 제거 |
| Parameter Store 이관     | 설정값 중앙화                   |
| Secrets Manager 이관     | 민감 시크릿 보호                |
| NACL 구성                | 다층 방어                       |

### 7.4 Phase 3: 중기 개선 (3개월+)

**목표**: 인프라 성장에 대비


| 작업           | 조건                                               |
| -------------- | -------------------------------------------------- |
| WAF 도입       | 공격 패턴 분석 후 규칙 정의 가능할 때              |
| Private Subnet | 인스턴스가 늘어나고 역할 분리 필요할 때            |
| VPN 재검토     | Private Subnet 도입 시 Tailscale vs AWS Client VPN |
| CodeDeploy     | 다중 인스턴스 배포 필요할 때                       |

### 7.5 의사결정 원칙

```
1. 현재 상황에 맞는 솔루션을 선택한다
   - "최고의 솔루션"이 아닌 "지금 우리에게 맞는 솔루션"

2. 완벽을 기다리지 않는다
   - Phase 1만 해도 공격 표면이 90% 감소

3. 확장 가능하게 설계한다
   - Tailscale → AWS Client VPN 전환 가능
   - SSM Parameter Store → Secrets Manager 이관 가능

4. 장애에 대비한다
   - 단일 경로 의존 금지
   - 백업 접근 경로 항상 준비
```

---

## 8. 결과 및 배운 점

### 8.1 개선 전후 비교


| 항목        | Before          | After                             | 개선 효과                    |
| ----------- | --------------- | --------------------------------- | ---------------------------- |
| SSH 접근    | 0.0.0.0/0       | Tailscale만                       | 공격 표면 99% 감소           |
| DB 접근     | 0.0.0.0/0 (Dev) | Tailscale만                       | SQL Injection 직접 공격 차단 |
| AWS 인증    | 장기 Access Key | OIDC 임시 토큰                    | 자격증명 유출 위험 제거      |
| 시크릿 관리 | 환경변수        | Parameter Store + Secrets Manager | 중앙화, 감사 가능            |
| 장애 대비   | 없음            | SSM 백업 경로                     | SPOF 제거                    |

### 8.2 핵심 교훈

**1. 공격은 규모와 상관없이 온다**

- 서비스 오픈 후 몇 분 만에 자동화된 공격 시작
- "우리는 작으니까 괜찮아"는 위험한 착각

**2. 보안과 편의성의 균형점을 찾아야 한다**

- 너무 엄격하면 개발 생산성 저하
- 너무 느슨하면 보안 취약
- VPN은 이 균형점을 찾는 좋은 방법

**3. 트레이드오프를 인식하고 문서화하라**

- Tailscale의 SaaS 의존성은 인지하고 선택
- 백업 경로(SSM)로 위험 완화
- 나중에 "왜 이렇게 했지?" 방지

**4. 단계적으로 접근하라**

- 한 번에 완벽하게 하려다 아무것도 못 함
- Phase 1만 해도 대부분의 위험 제거
- 상황 변화에 따라 Phase 2, 3 진행

---

## 부록: 의사결정 요약


| 결정         | 선택                | 대안                           | 핵심 근거                           |
| ------------ | ------------------- | ------------------------------ | ----------------------------------- |
| 접근 제어    | VPN                 | IP 화이트리스트, Bastion       | IP 변동 문제, 다양한 포트 접근 필요 |
| VPN 솔루션   | Tailscale           | AWS Client VPN, WireGuard      | 빠른 도입, 무료, GH Actions 연동    |
| VPN 백업     | SSM Session Manager | -                              | SPOF 방지                           |
| CI/CD 배포   | Tailscale + SSH     | Self-hosted Runner, CodeDeploy | 현재 규모에 적합, 간단              |
| CI/CD 백업   | SSM Run Command     | -                              | Tailscale 장애 대비                 |
| AWS 인증     | OIDC                | Access Key                     | 장기 자격증명 제거                  |
| CI/CD 시크릿 | GitHub Secrets      | -                              | Actions 전용                        |
| 앱 설정      | SSM Parameter Store | -                              | 무료, 버전 관리                     |
| 민감 시크릿  | Secrets Manager     | -                              | 자동 로테이션                       |

---

## 9. 현재 구현된 아키텍처 (2026-02-08 업데이트)

### 9.1 인프라 구조

초기 설계 이후, 인프라가 다음과 같이 발전했다.

```
┌─────────────────────────────────────────────────────────────────────────┐
│                      Billage 인프라 아키텍처 (현재)                      │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────────────┐ │
│  │   Dev VPC       │  │   Prod VPC      │  │   Management VPC        │ │
│  │  10.0.0.0/16    │  │  10.1.0.0/16    │  │  10.2.0.0/16            │ │
│  │                 │  │                 │  │                         │ │
│  │ [Public Subnet] │  │ [Public Subnet] │  │ [Public: 10.2.1.0/24]  │ │
│  │ ┌─────────────┐ │  │ ┌─────────────┐ │  │  ┌─────────────────┐   │ │
│  │ │Main Server  │ │  │ │Main Server  │ │  │  │ VPN Server      │   │ │
│  │ │FE+BE+DB+AI  │ │  │ │FE+BE+DB+AI  │ │  │  │ WireGuard+NAT   │   │ │
│  │ │t4g.medium   │ │  │ │t4g.medium   │ │  │  │ t4g.micro       │   │ │
│  │ └─────────────┘ │  │ └─────────────┘ │  │  └─────────────────┘   │ │
│  │ ┌─────────────┐ │  │                 │  │                         │ │
│  │ │Monitoring   │ │  │                 │  │ [Private: 10.2.2.0/24] │ │
│  │ │(Dev 로컬)   │ │  │                 │  │  ┌─────────────────┐   │ │
│  │ │t4g.small    │ │  │                 │  │  │ Monitoring      │   │ │
│  │ └─────────────┘ │  │                 │  │  │ 중앙 집중       │   │ │
│  └────────┬────────┘  └────────┬────────┘  │  │ t4g.small       │   │ │
│           │                    │           │  └─────────────────┘   │ │
│           │    VPC Peering     │           └──────────┬──────────────┘ │
│           └────────────────────┴──────────────────────┘                │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

### 9.2 주요 변경사항 (설계 → 구현)

| 항목 | 초기 설계 | 실제 구현 | 변경 사유 |
|------|----------|----------|----------|
| VPN 서버 | Tailscale만 | **Tailscale + WireGuard** | 이중화, SaaS 의존성 감소 |
| VPN 위치 | 각 서버에 설치 | **별도 Management VPC** | 관심사 분리, 보안 강화 |
| Monitoring | 각 환경별 분산 | **중앙 집중 (Private Subnet)** | 통합 관리, 비용 절감 |
| 네트워크 | 단일 VPC | **3개 VPC + Peering** | 환경 격리, 보안 경계 |

### 9.3 VPN 전략 (업데이트: 2026-02-09)

```
┌─────────────────────────────────────────────────────────────────┐
│                      WireGuard VPN (Primary)                     │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  VPN Server: Management VPC Public Subnet (10.2.1.x)            │
│  VPN Tunnel: 10.100.0.0/24                                      │
│  UDP Port: 51820                                                │
│                                                                  │
│  역할별 IP 할당:                                                 │
│  ├─ 10.100.0.1        → VPN Server                              │
│  ├─ 10.100.0.16/28    → DEVOPS (17-30): Full Access            │
│  ├─ 10.100.0.32/28    → BACKEND (33-46): SSH, MySQL, Spring    │
│  ├─ 10.100.0.48/28    → FRONTEND (49-62): Web Ports            │
│  └─ 10.100.0.64/28    → AIML (65-78): FastAPI, SSH             │
│                                                                  │
│  VPC Peering 라우팅:                                            │
│  ├─ VPN Client → VPN Server → SNAT → VPC Peering → Dev/Prod   │
│  └─ 응답: Dev/Prod → VPC Peering → VPN Server → VPN Client    │
│                                                                  │
│  ⚠️ 주의: VPC Peering은 peer VPC CIDR만 허용                   │
│  → VPN 터널 IP(10.100.0.0/24)는 Management CIDR 밖             │
│  → Masquerade(SNAT) 필수                                        │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

### 9.4 Security Group 현황

| 서버 | 포트 | 현재 상태 | 목표 상태 |
|------|------|----------|----------|
| Main (Dev/Prod) - SSH | 22 | 0.0.0.0/0 | Tailscale만 (100.64.0.0/10) |
| Main (Dev) - MySQL | 3306 | 0.0.0.0/0 | Tailscale + VPC |
| Main (Prod) - MySQL | 3306 | VPC 내부만 | ✅ 유지 |
| Monitoring - Grafana | 3000 | 0.0.0.0/0 | Tailscale만 |
| Monitoring - Prometheus | 9090 | 0.0.0.0/0 | Tailscale만 |
| VPN Server - WireGuard | 51820/UDP | 0.0.0.0/0 | ✅ 유지 (VPN이므로 외부 필요) |

### 9.5 구현 진행 상황 (2026-02-09 업데이트)

**완료:**
- [x] Management VPC 구축 (VPN 서버 + Monitoring 서버)
- [x] VPC Peering 설정 (Dev ↔ Management, Prod ↔ Management)
- [x] WireGuard VPN 서버 구축 (Primary VPN)
- [x] 역할별 VPN 사용자 등록 (DEVOPS, BACKEND, FRONTEND, AIML)
- [x] 중앙 집중식 모니터링 구축 (Prometheus + Grafana + Loki)
- [x] Security Group SSH/DB 제한 (VPN CIDR만 허용)

**진행 중:**
- [ ] VPN 서버 Masquerade 규칙 적용 (VPC Peering 라우팅 해결)
- [ ] iptables 역할별 필터링 (BACKEND → SSH+MySQL+Spring만 등)
- [ ] SSM 백업 경로 구성

**예정:**
- [ ] OIDC 전환 (Access Key 제거)
- [ ] SSM Run Command 배포 방식 구축
- [ ] 애플리케이션 포트 내부화 (8080, 3000, 5000 → localhost)

---

## 부록 B: 현재 의사결정 요약 (2026-02-09 업데이트)


| 결정 | 선택 | 구현 상태 | 비고 |
|------|------|----------|------|
| 접근 제어 | WireGuard VPN | ✅ 구축 완료 | 역할별 IP 할당 |
| VPN 서버 | Management VPC | ✅ 구축 완료 | 10.2.1.x |
| VPN 터널 | 10.100.0.0/24 | ✅ 운영 중 | 5명 사용자 등록 |
| 네트워크 분리 | 3 VPC + Peering | ✅ 구축 완료 | Dev, Prod, Management |
| Monitoring | 중앙 집중 (Private) | ✅ 구축 완료 | Management VPC |
| SSH 제한 | VPN CIDR만 허용 | ✅ 적용됨 | 10.100.0.0/24 |
| VPC Peering 라우팅 | Masquerade 필요 | 🔄 진행 중 | VPN IP가 VPC CIDR 밖 |
| 역할별 접근 제어 | iptables 필터링 | ⏳ 예정 | BACKEND, FRONTEND 등 |
| CI/CD 배포 | SSM Run Command | ⏳ 예정 | OIDC와 함께 |
| VPN 장애 대비 | SSM Session Manager | ⏳ 예정 | IAM 정책 추가 필요 |

---

*초기 작성일: 2026-02-03*
*마지막 업데이트: 2026-02-09*
*작성자: Billage 인프라팀*
