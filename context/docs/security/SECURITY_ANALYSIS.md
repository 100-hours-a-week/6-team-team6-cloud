# Billage 인프라 보안 분석 및 개선 보고서

> "보안은 선택이 아니라 필수다. 하지만 그 필수를 체감하기까지는 직접 공격을 당해봐야 한다."

## 목차

1. [들어가며](#1-들어가며)
2. [현재 인프라 구조 분석](#2-현재-인프라-구조-분석)
3. [발견된 보안 취약점](#3-발견된-보안-취약점)
4. [실제 공격 사례](#4-실제-공격-사례)
5. [해결 방안](#5-해결-방안)
6. [최종 보안 아키텍처](#6-최종-보안-아키텍처)
7. [마치며](#7-마치며)

---

## 1. 들어가며

### 1.1 이 문서를 작성하게 된 계기

처음 인프라를 구축할 때는 "일단 동작하게 만들자"가 목표였다. Terraform으로 VPC를 만들고, EC2를 띄우고, Security Group을 설정했다. 서비스가 잘 돌아가니 뿌듯했다.

그런데 어느 날, Nginx 로그를 확인하다가 이상한 요청들을 발견했다.

```
GET /.git/config HTTP/1.1
GET /?s=/Index/\think\app/invokefunction&function=call_user_func_array&vars[0]=system&vars[1][]=printenv
GET /actuator/env HTTP/1.1
```

**누군가 우리 서버를 해킹하려 하고 있었다.**

이 경험을 계기로 현재 인프라의 보안 상태를 전면 재검토하게 되었고, 이 문서는 그 과정과 결과를 기록한 것이다.

### 1.2 문서의 구조

```
현재 상태 분석 → 취약점 식별 → 실제 공격 사례 → 해결 방안 → 최종 아키텍처
```

단순히 "이렇게 하면 된다"가 아니라, **왜 이것이 문제인지**, **실제로 어떤 일이 발생할 수 있는지**를 중심으로 서술했다.

---

## 2. 현재 인프라 구조 분석

### 2.1 아키텍처 개요

현재 Billage 서비스는 **Big Bang 배포** 방식으로, 단일 EC2 인스턴스에 모든 서비스가 통합되어 있다.

```
┌─────────────────────────────────────────────────────────┐
│                      Internet                           │
└─────────────────────────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────┐
│                    Public Subnet                         │
│  ┌───────────────────────────────────────────────────┐  │
│  │              Main Server (EC2)                     │  │
│  │  ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐ │  │
│  │  │ Nginx   │ │ Next.js │ │ Spring  │ │ FastAPI │ │  │
│  │  │  :80    │ │  :3000  │ │  :8080  │ │  :5000  │ │  │
│  │  └─────────┘ └─────────┘ └─────────┘ └─────────┘ │  │
│  │  ┌─────────┐                                      │  │
│  │  │  MySQL  │                                      │  │
│  │  │  :3306  │                                      │  │
│  │  └─────────┘                                      │  │
│  └───────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────┘
```

### 2.2 Security Group 현황

Terraform 코드를 분석한 결과, 다음과 같은 Security Group 설정이 적용되어 있었다.

**Main Server Security Group (`modules/security-group/main.tf`)**

| 포트 | 서비스 | 허용 CIDR | 비고 |
|------|--------|-----------|------|
| 22 | SSH | `0.0.0.0/0` | ⚠️ 전역 노출 |
| 80 | HTTP | `0.0.0.0/0` | - |
| 443 | HTTPS | `0.0.0.0/0` | - |
| 3306 | MySQL | Dev: `0.0.0.0/0` / Prod: VPC만 | ⚠️ Dev 취약 |
| 8080 | Spring Boot | `0.0.0.0/0` | ⚠️ 직접 노출 |
| 3000 | Next.js | `0.0.0.0/0` | ⚠️ 직접 노출 |
| 5000 | FastAPI | `0.0.0.0/0` | ⚠️ 직접 노출 |

### 2.3 미구현 보안 요소

| 요소 | 상태 | 역할 |
|------|------|------|
| NACL | ❌ 미구현 | 서브넷 레벨 방화벽 |
| WAF | ❌ 미구현 | 웹 애플리케이션 공격 방어 |
| VPN | ❌ 미구현 | 관리 접근 보호 |
| Bastion Host | ❌ 미구현 | SSH 접근 게이트웨이 |

---

## 3. 발견된 보안 취약점

### 3.1 취약점 요약

분석 결과, 다음과 같은 보안 취약점을 식별했다.

| # | 취약점 | 심각도 | 영향 |
|---|--------|--------|------|
| 1 | SSH 포트 전역 노출 | 🔴 Critical | 브루트포스 공격, 무단 접근 |
| 2 | 데이터베이스 전역 노출 (Dev) | 🔴 Critical | 데이터 유출, SQL Injection |
| 3 | 애플리케이션 포트 직접 노출 | 🟠 High | API 직접 공격, 정보 수집 |
| 4 | WAF 부재 | 🟠 High | OWASP Top 10 공격에 무방비 |
| 5 | CI/CD 장기 자격증명 | 🟠 High | 자격증명 탈취 시 전체 침해 |
| 6 | 화이트리스트 지옥 | 🟠 High | IP 관리 불가능, 운영 비효율 |
| 7 | NACL 미구현 | 🟡 Medium | 다층 방어 부재 |

### 3.2 취약점 상세 분석

#### 취약점 #1: SSH 포트 전역 노출

**현재 설정 (`envs/prod/variables.tf:52`)**
```hcl
variable "ssh_allowed_cidr" {
  description = "SSH 접근 허용 CIDR (보안을 위해 특정 IP 권장)"
  type        = list(string)
  default     = ["0.0.0.0/0"]  # ⚠️ 전 세계에서 접근 가능
}
```

**문제점**
- 전 세계 어디서든 SSH 접속 시도 가능
- 브루트포스 공격의 표적이 됨
- SSH 키가 유출되면 즉시 서버 장악

**실제 위험 시나리오**
```bash
# 공격자가 수행할 수 있는 브루트포스 공격
hydra -l ubuntu -P /usr/share/wordlists/rockyou.txt ssh://your-server-ip

# 또는 알려진 취약한 키를 사용한 접속 시도
ssh -i leaked_key.pem ubuntu@your-server-ip
```

---

#### 취약점 #2: 데이터베이스 전역 노출 (Dev 환경)

**현재 설정 (`envs/dev/variables.tf:58`)**
```hcl
variable "db_allowed_cidr" {
  description = "DB 접근 허용 CIDR"
  type        = list(string)
  default     = ["0.0.0.0/0"]  # ⚠️ 개발 환경이라고 방심
}
```

**문제점**
- MySQL 포트(3306)가 인터넷에 직접 노출
- SQL Injection 없이도 직접 DB 접속 시도 가능
- 약한 패스워드 사용 시 데이터 전체 유출

**실제 위험 시나리오**
```bash
# 공격자가 직접 MySQL 접속 시도
mysql -h your-server-ip -u root -p

# Nmap으로 MySQL 버전 확인 후 알려진 취약점 공격
nmap -sV -p 3306 your-server-ip
```

---

#### 취약점 #3: 애플리케이션 포트 직접 노출

**현재 설정 (`modules/security-group/main.tf:47-71`)**
```hcl
# Spring Boot - 직접 노출
ingress {
  from_port   = 8080
  to_port     = 8080
  cidr_blocks = ["0.0.0.0/0"]  # ⚠️ 백엔드 직접 접근 가능
}

# FastAPI - 직접 노출
ingress {
  from_port   = 5000
  to_port     = 5000
  cidr_blocks = ["0.0.0.0/0"]  # ⚠️ AI 서버 직접 접근 가능
}
```

**문제점**
- Nginx를 우회하여 백엔드 직접 접근 가능
- Spring Boot Actuator, Swagger 등 민감한 엔드포인트 노출
- Rate Limiting, 보안 헤더 등 Nginx 보안 기능 무력화

---

#### 취약점 #4: CI/CD 파이프라인 장기 자격증명

**현재 GitHub Actions 구성**
```yaml
# secrets에 저장된 장기 자격증명
AWS_ACCESS_KEY_ID: ${{ secrets.AWS_ACCESS_KEY_ID }}
AWS_SECRET_ACCESS_KEY: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
SSH_PRIVATE_KEY: ${{ secrets.SSH_PRIVATE_KEY }}
```

**문제점**

| 항목 | 위험 |
|------|------|
| AWS Access Key | Rotate하지 않으면 영구적으로 유효 |
| SSH Private Key | 유출 시 서버 직접 접근 가능 |
| 권한 범위 | IAM 사용자 권한이 과도할 수 있음 |

**실제 위험 시나리오**
- GitHub 저장소가 실수로 public 전환 시 secrets 노출 가능성
- Workflow 로그에 secrets가 마스킹되지 않고 출력될 수 있음
- 퇴사자가 있어도 키가 rotate되지 않으면 계속 유효

---

#### 취약점 #5: 화이트리스트 지옥 (Whitelist Hell)

보안을 강화하기 위해 SSH나 DB 접근을 특정 IP로 제한하면 어떻게 될까?

**시나리오: "개발자 IP를 Security Group에 등록하자"**

```hcl
# 처음엔 이렇게 시작한다
ssh_allowed_cidr = [
  "123.456.789.1/32",   # 개발자 A (집)
  "123.456.789.2/32",   # 개발자 B (집)
]
```

**문제 1: 개발자 IP는 계속 변한다**

```
월요일: 개발자 A가 집에서 작업 → IP: 123.456.789.1
화요일: 개발자 A가 카페에서 작업 → IP: 111.222.333.4 ← 접속 불가!
수요일: 개발자 A의 집 공유기 재부팅 → IP: 987.654.321.0 ← 또 접속 불가!
```

**결과**: 매번 Security Group 수정 → Terraform apply → 대기...

**문제 2: 팀이 커지면 관리 불가능**

```hcl
# 6개월 후...
ssh_allowed_cidr = [
  "123.456.789.1/32",   # 개발자 A (집) - 아직 유효한가?
  "123.456.789.2/32",   # 개발자 B (집)
  "111.222.333.4/32",   # 개발자 A (카페)
  "222.333.444.5/32",   # 개발자 C (집)
  "333.444.555.6/32",   # 개발자 C (회사)
  "444.555.666.7/32",   # 누구 IP지?
  "555.666.777.8/32",   # 퇴사자 IP인 것 같은데...
  # ... 수십 개의 IP
]
```

**문제 3: GitHub Actions Runner IP**

CI/CD 파이프라인에서 서버에 접근해야 할 때 더 심각해진다.

```yaml
# GitHub Actions에서 서버 배포
- name: Deploy to Server
  run: ssh ubuntu@${{ secrets.SERVER_IP }} "docker-compose up -d"
```

**GitHub Actions Runner의 특성:**
- GitHub이 관리하는 공유 Runner 사용 시 **IP가 매번 다름**
- GitHub은 Runner IP 대역을 공개하지만, **수천 개의 IP 대역**
- 이 모든 IP를 Security Group에 등록? → **비현실적**

```hcl
# 이론적으로 가능하지만...
ssh_allowed_cidr = [
  "20.37.0.0/17",      # GitHub Actions IP 대역 1
  "20.38.0.0/17",      # GitHub Actions IP 대역 2
  "20.39.0.0/17",      # ...
  # 수십 개의 대역 추가 필요
  # 그리고 GitHub이 대역을 변경하면? 다시 업데이트!
]
```

**문제 4: 결국 0.0.0.0/0으로 회귀**

```hcl
# "아 귀찮아, 그냥 다 열자"
ssh_allowed_cidr = ["0.0.0.0/0"]  # ← 원점 회귀
```

> 이것이 **화이트리스트 지옥**이다.
> 보안을 강화하려 했지만, 관리 비용이 너무 커서 결국 포기하게 된다.

---

## 4. 실제 공격 사례

### 4.1 발견 경위

평소처럼 서버 상태를 확인하던 중, Nginx 액세스 로그에서 이상한 패턴을 발견했다.

```bash
ubuntu@ip-10-1-1-114:~$ cat /var/log/nginx/billage_access.log
```

### 4.2 공격 로그 분석

#### 공격 유형 1: Git 설정 파일 탈취 시도

```log
216.81.245.109 - - [29/Jan/2026:00:19:36 +0900] "GET /.git/config HTTP/1.1" 404 2254
216.81.245.109 - - [29/Jan/2026:00:21:52 +0900] "GET /.git/config HTTP/1.1" 404 2254
```

**공격 의도**
- `.git/config` 파일에는 원격 저장소 URL, 사용자 정보 등이 포함
- 성공 시 소스코드 저장소 접근 → 전체 코드베이스 탈취 가능
- 코드에 하드코딩된 API 키, DB 비밀번호 등 추출

**우리의 상황**: 404 반환 (Nginx가 정적 파일로 서빙하지 않음) → **방어 성공**

---

#### 공격 유형 2: ThinkPHP RCE (Remote Code Execution) 공격

```log
98.88.247.68 - - [29/Jan/2026:00:29:31 +0900]
"GET /?s=/Index/\x5Cthink\x5Capp/invokefunction&function=call_user_func_array&vars[0]=system&vars[1][]=printenv HTTP/1.1"
```

**공격 분석**

이 요청을 디코딩하면:
```
/?s=/Index/\think\app/invokefunction
  &function=call_user_func_array
  &vars[0]=system
  &vars[1][]=printenv
```

**공격 의도**
- ThinkPHP 프레임워크의 알려진 RCE 취약점(CVE-2018-20062) 악용
- `system('printenv')` 실행 → 서버의 환경변수 출력
- 환경변수에는 DB 비밀번호, API 키 등 민감 정보 포함

**성공했다면?**
```bash
# 공격자가 얻었을 정보
DB_PASSWORD=super_secret_password
AWS_ACCESS_KEY_ID=AKIA...
JWT_SECRET=my_jwt_secret
```

**우리의 상황**: ThinkPHP를 사용하지 않음 → **방어 성공** (단, 우연히 방어된 것)

---

#### 공격 유형 3: Laravel Ignition 취약점 공격

```log
98.88.247.68 - - [29/Jan/2026:00:29:33 +0900] "GET /_ignition/health-check HTTP/1.1" 404
98.88.247.68 - - [29/Jan/2026:00:29:34 +0900] "GET /_ignition/execute-solution HTTP/1.1" 404
```

**공격 의도**
- Laravel Ignition의 RCE 취약점(CVE-2021-3129) 악용
- `execute-solution` 엔드포인트로 임의 코드 실행
- 서버 완전 장악 가능

**우리의 상황**: Laravel을 사용하지 않음 → **방어 성공** (단, 우연히 방어된 것)

---

#### 공격 유형 4: Spring Boot Actuator 정보 수집

```log
98.88.247.68 - - [29/Jan/2026:00:29:37 +0900] "GET /actuator/env HTTP/1.1" 404
98.88.247.68 - - [29/Jan/2026:00:29:37 +0900] "GET /env HTTP/1.1" 404
98.88.247.68 - - [29/Jan/2026:00:29:38 +0900] "GET /v2/api-docs HTTP/1.1" 404
```

**공격 의도**
- Spring Boot Actuator 엔드포인트 탐색
- `/actuator/env`: 환경변수, 설정값 노출
- `/api-docs`: Swagger 문서 → API 구조 파악 → 취약점 분석

**위험한 점**: 우리는 실제로 Spring Boot를 사용 중!

만약 Actuator가 기본 설정으로 활성화되어 있었다면:
```json
// /actuator/env 응답 예시
{
  "spring.datasource.password": "******",
  "spring.datasource.url": "jdbc:mysql://localhost:3306/billage",
  "jwt.secret": "******"
}
```

**우리의 상황**: Nginx에서 `/actuator` 경로를 백엔드로 프록시하지 않음 → **방어 성공**

---

#### 공격 유형 5: HTTP Flood & CLOSE_WAIT 공격

로그 분석 후, 비정상적인 소켓 상태를 확인했다.

```bash
ubuntu@ip-10-1-1-114:~$ sudo lsof -i :8080
```

**발견된 현상**

수많은 TCP 연결이 `CLOSE_WAIT` 상태로 남아있었다.

```
COMMAND   PID   USER   FD   TYPE  DEVICE  STATE
java      1234  root   45u  IPv4  12345   CLOSE_WAIT
java      1234  root   46u  IPv4  12346   CLOSE_WAIT
java      1234  root   47u  IPv4  12347   CLOSE_WAIT
... (수십 개의 CLOSE_WAIT 연결)
```

**공격 분석**

```
정상적인 TCP 종료:
Client → FIN → Server
Client ← ACK ← Server
Client ← FIN ← Server (close() 호출)
Client → ACK → Server
연결 종료 ✓

공격자의 행동:
Client → FIN → Server
(응답 기다리지 않고 연결 끊음)
Server: CLOSE_WAIT 상태로 대기... (소켓 점유)
```

**공격 의도**
- 서버의 소켓 리소스 고갈
- 정상 사용자의 연결 불가
- 서비스 거부(DoS) 상태 유발

**IP 추적 결과**

공격 IP들을 추적한 결과:
- `98.88.247.68` → 미국
- `216.81.245.109` → 홍콩
- 기타 암스테르담, 러시아 등

**결론**: 자동화된 봇에 의한 무차별 스캔 및 공격

---

### 4.3 공격 타임라인 정리

```
00:19:36 - Git 설정 파일 탈취 시도 (216.81.245.109)
00:21:52 - Git 설정 파일 재시도
00:29:28 - 정찰 시작 (98.88.247.68)
00:29:29 - EC2 도메인으로 접근 시도
00:29:31 - ThinkPHP RCE 공격
00:29:32 - PHP 프레임워크 취약점 스캔
00:29:33 - Laravel Ignition 공격
00:29:35 - 디버그 엔드포인트 스캔
00:29:37 - Spring Boot Actuator 스캔
00:29:38 - API 문서 스캔
```

**10초 만에 10개 이상의 알려진 취약점을 자동으로 스캔했다.**

이것은 사람이 아니라 자동화된 공격 도구다.

---

### 4.4 교훈

> "우리 서비스가 작아서 해커가 관심 없을 거야"라는 생각은 위험하다.

- 공격자는 **특정 서비스를 노리는 게 아니라**, 인터넷에 노출된 **모든 서버를 무차별 스캔**한다
- 서비스 배포 후 **수 분 내에** 자동화된 공격이 시작된다
- 우연히 방어된 것과 **의도적으로 방어한 것**은 다르다

---

## 5. 해결 방안

### 5.1 즉시 조치 (Quick Wins)

#### 5.1.1 SSH 접근 제한

**Before**
```hcl
# envs/prod/variables.tf
ssh_allowed_cidr = ["0.0.0.0/0"]
```

**After**
```hcl
# 방법 1: 특정 IP만 허용
ssh_allowed_cidr = ["123.456.789.0/32"]  # 관리자 IP

# 방법 2: VPN을 통해서만 접근 (권장)
ssh_allowed_cidr = ["10.0.0.0/8"]  # VPN 대역
```

---

#### 5.1.2 데이터베이스 접근 제한

**Before**
```hcl
# envs/dev/variables.tf
db_allowed_cidr = ["0.0.0.0/0"]
```

**After**
```hcl
# VPC 내부에서만 접근
db_allowed_cidr = ["10.0.0.0/16"]
```

---

#### 5.1.3 모니터링 UI 접근 제한

**Before**
```hcl
monitoring_allowed_cidr = ["0.0.0.0/0"]
```

**After**
```hcl
monitoring_allowed_cidr = ["123.456.789.0/32"]  # 관리자 IP만
```

---

### 5.2 단기 개선 (1-2주)

#### 5.2.1 애플리케이션 포트 내부화

Nginx만 외부에 노출하고, 백엔드/AI 서버는 내부 통신만 허용한다.

**Security Group 수정**
```hcl
# Spring Boot - localhost만 허용
ingress {
  description = "Spring Boot - Internal only"
  from_port   = 8080
  to_port     = 8080
  protocol    = "tcp"
  cidr_blocks = ["127.0.0.1/32"]
}

# FastAPI - localhost만 허용
ingress {
  description = "FastAPI - Internal only"
  from_port   = 5000
  to_port     = 5000
  protocol    = "tcp"
  cidr_blocks = ["127.0.0.1/32"]
}
```

**결과**: 외부에서 `http://서버IP:8080` 접근 불가

---

#### 5.2.2 NACL 추가

서브넷 레벨에서 추가 방어 계층을 구성한다.

```hcl
# modules/vpc/nacl.tf
resource "aws_network_acl" "public" {
  vpc_id     = aws_vpc.main.id
  subnet_ids = [aws_subnet.public.id]

  # 인바운드: 허용할 포트만 명시
  ingress {
    protocol   = "tcp"
    rule_no    = 100
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 443
    to_port    = 443
  }

  ingress {
    protocol   = "tcp"
    rule_no    = 110
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 80
    to_port    = 80
  }

  # SSH는 관리자 IP만
  ingress {
    protocol   = "tcp"
    rule_no    = 120
    action     = "allow"
    cidr_block = "123.456.789.0/32"
    from_port  = 22
    to_port    = 22
  }

  # Ephemeral ports (응답용)
  ingress {
    protocol   = "tcp"
    rule_no    = 200
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 1024
    to_port    = 65535
  }

  # 아웃바운드: 모두 허용
  egress {
    protocol   = "-1"
    rule_no    = 100
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 0
    to_port    = 0
  }

  tags = {
    Name = "${var.project_name}-${var.env}-public-nacl"
  }
}
```

---

#### 5.2.3 CI/CD OIDC 전환

장기 자격증명(Access Key)을 제거하고 OIDC로 전환한다.

**Step 1: AWS에 OIDC Provider 생성**
```hcl
# modules/github-oidc/main.tf
resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}
```

**Step 2: IAM Role 생성**
```hcl
resource "aws_iam_role" "github_actions" {
  name = "github-actions-deploy-role"

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
          # 특정 리포지토리, 특정 브랜치만 허용
          "token.actions.githubusercontent.com:sub" = "repo:your-org/your-repo:ref:refs/heads/main"
        }
      }
    }]
  })
}

# 최소 권한 정책
resource "aws_iam_role_policy" "deploy_policy" {
  name = "deploy-policy"
  role = aws_iam_role.github_actions.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken",
          "ecr:BatchCheckLayerAvailability",
          "ecr:PutImage"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ssm:SendCommand",
          "ssm:GetCommandInvocation"
        ]
        Resource = [
          "arn:aws:ssm:*:*:document/AWS-RunShellScript",
          "arn:aws:ec2:*:*:instance/*"
        ]
      }
    ]
  })
}
```

**Step 3: GitHub Actions Workflow 수정**
```yaml
# .github/workflows/deploy.yml
jobs:
  deploy:
    runs-on: ubuntu-latest
    permissions:
      id-token: write   # OIDC 토큰 요청 권한
      contents: read

    steps:
      - name: Configure AWS credentials
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::123456789:role/github-actions-deploy-role
          aws-region: ap-northeast-2
          # Access Key가 필요 없음!
```

**장점**
- Access Key 불필요 (단기 토큰 자동 발급)
- 특정 리포지토리/브랜치만 허용 가능
- 자격증명 rotate 불필요

---

#### 5.2.4 SSH 키 대신 SSM 사용

SSH 키를 secrets에 저장하는 대신, AWS Systems Manager를 사용한다.

**EC2에 SSM Agent 설정 (IAM Role)**
```hcl
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}
```

**GitHub Actions에서 배포**
```yaml
- name: Deploy via SSM
  run: |
    aws ssm send-command \
      --instance-ids ${{ vars.INSTANCE_ID }} \
      --document-name "AWS-RunShellScript" \
      --parameters 'commands=["cd /app && docker-compose pull && docker-compose up -d"]' \
      --output text
```

**장점**
- SSH 포트(22) 완전히 닫을 수 있음
- SSH 키 관리 불필요
- 모든 명령이 CloudTrail에 기록됨

---

### 5.3 중장기 개선 (1개월+)

#### 5.3.1 안전한 접근 경로 구축: VPN vs Proxy Server

화이트리스트 지옥을 해결하기 위해 두 가지 접근 방식을 검토했다.

**방식 1: VPN (Virtual Private Network)**

```
개발자 PC → VPN 클라이언트 → VPN 서버 → VPC 내부 리소스
                   │
         암호화된 터널로 VPC에 "가상으로 들어감"
```

**방식 2: Proxy Server (Bastion Host / Jump Server)**

```
개발자 PC → SSH → Bastion Host → SSH → 내부 서버
                      │
         중간 서버를 경유해서 접근
```

**VPN vs Proxy Server 비교**

| 항목 | VPN | Proxy Server (Bastion) |
|------|-----|------------------------|
| **접근 범위** | VPC 내 모든 리소스 (SSH, DB, Web UI 등) | SSH 접근만 (포트 포워딩 필요) |
| **사용 편의성** | VPN 연결 후 로컬처럼 사용 | SSH 명령어 또는 터널링 필요 |
| **DB 접근** | MySQL Workbench로 직접 연결 가능 | SSH 터널링 설정 필요 |
| **모니터링 UI** | 브라우저에서 직접 접근 | SSH 터널 후 localhost로 접근 |
| **보안** | 전체 네트워크 접근 권한 부여 | 필요한 서버만 경유 |
| **장애 영향** | VPN 장애 시 모든 관리 접근 불가 | Bastion 장애 시 SSH만 불가 |
| **비용** | VPN 솔루션 비용 | EC2 1대 비용 |
| **복잡도** | 인증서/계정 관리 필요 | SSH 키만 관리 |

**우리의 선택: VPN**

현재 상황에서 VPN을 선택한 이유:

1. **다양한 접근 필요**: SSH뿐 아니라 MySQL, Grafana, Prometheus 등 여러 포트 접근 필요
2. **개발 편의성**: DB 클라이언트, 브라우저에서 직접 접근하는 것이 생산성에 유리
3. **팀 규모**: 소규모 팀에서 Bastion 경유는 오버헤드

> 단, 규모가 커지고 Private Subnet이 도입되면 Bastion Host도 함께 고려한다.
> VPN은 "관리 접근용", Bastion은 "긴급 접근/장애 대응용"으로 역할 분리 가능.

---

#### 5.3.2 VPN 솔루션 비교 및 선택

VPN 솔루션은 크게 두 가지 유형으로 나뉜다.

**VPN 유형**

| 유형 | 설명 | 사용 사례 |
|------|------|----------|
| **Site-to-Site VPN** | 네트워크 ↔ 네트워크 연결 | 온프레미스 ↔ AWS 연결 |
| **Client-to-Site VPN** | 개인 PC → 네트워크 연결 | 원격 근무자가 사내망 접속 |

우리의 상황: **개발자 개인 PC에서 AWS VPC로 접근** → **Client-to-Site VPN**

**Client-to-Site VPN 솔루션 비교**

| 솔루션 | 설치 복잡도 | 비용 | 관리 부담 | GitHub Actions 지원 | 안정성 |
|--------|-----------|------|----------|-------------------|--------|
| **Tailscale** | ⭐ 매우 쉬움 | 무료 (100기기) | 낮음 | ✅ 공식 Action | ⭐⭐⭐ SaaS 의존 |
| **WireGuard** | ⭐⭐ 보통 | 무료 | 중간 | ⭐⭐ 수동 설정 | ⭐⭐⭐⭐ 자체 운영 |
| **OpenVPN** | ⭐⭐⭐ 복잡 | 무료 | 높음 | ⭐⭐ 수동 설정 | ⭐⭐⭐⭐ 자체 운영 |
| **AWS Client VPN** | ⭐⭐ 보통 | $72+/월 | 낮음 | ⭐ 복잡 | ⭐⭐⭐⭐⭐ AWS 관리형 |

**각 솔루션 상세 분석**

**1. Tailscale**
```
장점:
- 5분 만에 설치 완료 (apt install tailscale && tailscale up)
- NAT traversal 자동 처리 (복잡한 네트워크 환경에서도 동작)
- 중앙 관리 콘솔 제공
- GitHub Actions 공식 지원
- MagicDNS로 호스트명 자동 할당

단점:
- Tailscale SaaS에 의존 (메타데이터가 Tailscale 서버 경유)
- Tailscale 서비스 장애 시 새 연결 불가
- 엔터프라이즈 기능은 유료
```

**2. WireGuard**
```
장점:
- 커널 레벨 구현으로 성능 최고
- 코드베이스가 작아 보안 감사 용이
- 완전 무료, 자체 운영
- 외부 의존성 없음

단점:
- 서버 설정 직접 필요 (키 생성, 라우팅, 방화벽)
- 동적 IP 환경에서 추가 설정 필요
- 관리 UI 없음 (CLI만)
```

**3. OpenVPN**
```
장점:
- 오랜 역사, 검증된 안정성
- 대부분의 기업 환경에서 사용
- 다양한 인증 방식 지원

단점:
- 설정 복잡 (PKI 인프라 필요)
- 성능이 WireGuard 대비 낮음
- 클라이언트 호환성 이슈 가끔 발생
```

**4. AWS Client VPN**
```
장점:
- AWS 관리형으로 운영 부담 최소
- IAM, Active Directory 연동 가능
- CloudWatch 로그 자동 연동
- 고가용성 (AWS 인프라)

단점:
- 비용이 높음 ($72+/월 기본)
- 인증서 관리 필요
- GitHub Actions 연동이 복잡
```

---

#### 5.3.3 우리의 VPN 전략: 단계적 도입

**현재 우리 상황 분석**

```
인프라 현황:
- Public Subnet만 존재 (Private Subnet 없음)
- Single Instance에 Big Bang 배포
- 팀 규모: 소규모 (5명 이하)
- 예산: 제한적
- 우선순위: 빠른 도입 > 완벽한 구성
```

**Phase 1: Tailscale 도입 (현재 → 1주일)**

현재 구조에서는 **Tailscale**이 가장 적합하다.

```
선택 근거:
✅ 설치 5분 만에 완료 - 빠른 도입
✅ 무료 (100기기까지) - 비용 부담 없음
✅ Public Subnet에서도 바로 사용 가능
✅ GitHub Actions 공식 지원
✅ 팀원 온보딩 간편 (링크 공유만으로 초대)

감수해야 할 점:
⚠️ Tailscale SaaS 의존성
⚠️ Tailscale 서비스 장애 시 영향
```

**Tailscale 설치 (서버)**
```bash
# EC2 인스턴스에서
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up --advertise-tags=tag:server --hostname=billage-main
```

**Tailscale 설치 (개발자 PC)**
```bash
# macOS
brew install tailscale
tailscale up

# Windows
# https://tailscale.com/download 에서 설치
```

**Security Group 수정**
```hcl
# Tailscale은 100.x.x.x 대역 사용
variable "tailscale_cidr" {
  default = "100.64.0.0/10"  # Tailscale CGNAT 대역
}

# SSH - Tailscale에서만
ingress {
  description = "SSH from Tailscale"
  from_port   = 22
  to_port     = 22
  protocol    = "tcp"
  cidr_blocks = [var.tailscale_cidr]
}
```

**Phase 2: 안정성 확보 (1개월 후)**

Tailscale에 의존하는 것의 리스크를 줄이기 위한 백업 접근 경로 구성.

```
Tailscale 장애 시나리오:
- Tailscale 서비스 다운
- 새로운 VPN 연결 불가
- 기존 연결은 일정 시간 유지되다가 끊김
- 서버 관리 불가 상태

대응 방안:
1. AWS SSM Session Manager를 백업 경로로 구성
2. 긴급 시 SSM으로 서버 접근 가능
```

**SSM 백업 경로 구성**
```hcl
# EC2 IAM Role에 SSM 정책 추가
resource "aws_iam_role_policy_attachment" "ssm_backup" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}
```

```bash
# Tailscale 장애 시 SSM으로 접근
aws ssm start-session --target i-1234567890abcdef0
```

**Phase 3: Private Subnet 도입 시 (3개월+ 후)**

인프라가 성장하여 Private Subnet이 도입되면:

```
현재 (Phase 1-2):
┌─────────────────────────────────────┐
│           Public Subnet             │
│  ┌─────────┐                       │
│  │  Main   │ ← Tailscale 직접 연결 │
│  │ Server  │                       │
│  └─────────┘                       │
└─────────────────────────────────────┘

미래 (Phase 3):
┌─────────────────────────────────────┐
│           Public Subnet             │
│  ┌─────────┐       ┌─────────┐    │
│  │   ALB   │       │ Bastion │    │
│  └────┬────┘       └────┬────┘    │
└───────┼─────────────────┼─────────┘
        │                 │
┌───────┼─────────────────┼─────────┐
│       ▼   Private Subnet│         │
│  ┌─────────┐       ┌────▼────┐   │
│  │   App   │       │   DB    │   │
│  │ Servers │       │ Server  │   │
│  └─────────┘       └─────────┘   │
└───────────────────────────────────┘

이 시점에 검토할 옵션:
- AWS Client VPN (관리형, 고가용성 필요 시)
- WireGuard on Bastion (비용 절감 필요 시)
- Tailscale Subnet Router (현재 방식 확장)
```

**Tailscale Subnet Router 설정 (Phase 3용)**
```bash
# Bastion 또는 VPN 게이트웨이 역할을 할 서버에서
sudo tailscale up \
  --advertise-routes=10.0.0.0/16 \  # Private Subnet 대역 광고
  --accept-dns=false
```

---

#### 5.3.4 GitHub Actions 배포 방식 비교

GitHub Actions에서 AWS 서버에 배포하는 방법은 여러 가지가 있다.

**방식 비교**

| 방식 | 설명 | 장점 | 단점 |
|------|------|------|------|
| **SSH 직접 접속** | Runner에서 서버로 SSH | 간단, 직관적 | IP 화이트리스트 문제 |
| **Self-hosted Runner** | VPC 내부에 Runner 배치 | 네트워크 제약 없음 | Runner 관리 필요, 비용 |
| **SSM Run Command** | AWS SSM으로 명령 실행 | SSH 불필요, 감사 로그 | AWS 권한 필요 |
| **CodeDeploy** | AWS 배포 서비스 사용 | 롤백, 배포 전략 지원 | 설정 복잡, Agent 필요 |
| **Tailscale + SSH** | Tailscale 네트워크 경유 | 간편, 무료 | Tailscale 의존 |

**각 방식 상세 분석**

**1. Self-hosted Runner**
```
얻는 것:
+ VPC 내부에서 실행되어 네트워크 제약 없음
+ GitHub 공용 Runner 대기 시간 없음
+ 민감한 코드가 외부로 나가지 않음
+ 캐시 유지로 빌드 속도 향상

잃는 것:
- EC2 비용 발생 (t4g.small ~$12/월)
- Runner 관리 필요 (업데이트, 모니터링)
- Runner 장애 시 배포 불가
- 스케일링 직접 관리

적합한 상황:
→ 배포 빈도가 높고, 빌드 시간이 긴 경우
→ 민감한 코드/데이터를 다루는 경우
→ VPC 내부 리소스에 빈번하게 접근해야 하는 경우
```

**2. SSM Run Command**
```
얻는 것:
+ SSH 포트 완전히 닫을 수 있음
+ SSH 키 관리 불필요
+ CloudTrail에 모든 명령 기록
+ IAM으로 세밀한 권한 제어

잃는 것:
- 실시간 출력 확인 어려움
- 복잡한 배포 스크립트 실행 시 불편
- AWS API 호출 오버헤드
- OIDC 또는 IAM 설정 필요

적합한 상황:
→ 간단한 배포 명령 (docker-compose up 등)
→ 보안이 최우선인 환경
→ SSH 접근을 완전히 차단하고 싶은 경우
```

**3. CodeDeploy**
```
얻는 것:
+ Blue/Green, Rolling 등 배포 전략 지원
+ 자동 롤백 기능
+ 배포 히스토리 관리
+ 여러 인스턴스 동시 배포

잃는 것:
- 설정 복잡 (appspec.yml, 배포 그룹 등)
- CodeDeploy Agent 설치/관리 필요
- 단순 배포에는 오버스펙
- 학습 곡선

적합한 상황:
→ 여러 인스턴스에 배포하는 경우
→ 무중단 배포가 필수인 경우
→ 자동 롤백이 필요한 프로덕션 환경
```

**4. Tailscale + SSH (GitHub Action)**
```
얻는 것:
+ 설정 간단 (Tailscale Action 사용)
+ IP 화이트리스트 불필요
+ 무료
+ SSH로 복잡한 작업 가능

잃는 것:
- Tailscale 서비스 의존
- Tailscale 장애 시 배포 불가
- SSH 키 관리 필요

적합한 상황:
→ 소규모 팀, 단일 서버
→ 빠른 도입이 필요한 경우
→ 이미 Tailscale을 사용 중인 경우
```

**우리의 선택: Tailscale + SSH → SSM Run Command 병행**

```
현재 상황:
- 단일 인스턴스 (Big Bang 배포)
- 복잡한 배포 전략 불필요
- 빠른 도입 필요

선택 전략:
1. 메인: Tailscale + SSH (간편, 무료)
2. 백업: SSM Run Command (Tailscale 장애 대비)
3. 미래: CodeDeploy (인스턴스 늘어나면 검토)
```

**구현 예시: Tailscale + SSH (메인)**
```yaml
# .github/workflows/deploy.yml
name: Deploy

on:
  push:
    branches: [main]

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Setup Tailscale
        uses: tailscale/github-action@v2
        with:
          oauth-client-id: ${{ secrets.TAILSCALE_CLIENT_ID }}
          oauth-secret: ${{ secrets.TAILSCALE_CLIENT_SECRET }}
          tags: tag:ci

      - name: Deploy via SSH
        env:
          SSH_PRIVATE_KEY: ${{ secrets.SSH_PRIVATE_KEY }}
        run: |
          mkdir -p ~/.ssh
          echo "$SSH_PRIVATE_KEY" > ~/.ssh/id_rsa
          chmod 600 ~/.ssh/id_rsa
          ssh -o StrictHostKeyChecking=no ubuntu@billage-main \
            "cd /app && docker-compose pull && docker-compose up -d"
```

**구현 예시: SSM Run Command (백업)**
```yaml
# .github/workflows/deploy-ssm.yml
name: Deploy via SSM (Backup)

on:
  workflow_dispatch:  # 수동 실행 (Tailscale 장애 시)

jobs:
  deploy:
    runs-on: ubuntu-latest
    permissions:
      id-token: write
      contents: read

    steps:
      - name: Configure AWS credentials (OIDC)
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::123456789:role/github-actions-deploy
          aws-region: ap-northeast-2

      - name: Deploy via SSM
        run: |
          COMMAND_ID=$(aws ssm send-command \
            --instance-ids ${{ vars.INSTANCE_ID }} \
            --document-name "AWS-RunShellScript" \
            --parameters 'commands=["cd /app && docker-compose pull && docker-compose up -d"]' \
            --query 'Command.CommandId' \
            --output text)

          # 명령 완료 대기
          aws ssm wait command-executed \
            --instance-id ${{ vars.INSTANCE_ID }} \
            --command-id $COMMAND_ID

          # 결과 확인
          aws ssm get-command-invocation \
            --instance-id ${{ vars.INSTANCE_ID }} \
            --command-id $COMMAND_ID \
            --query 'StandardOutputContent' \
            --output text
```

---

#### 5.3.5 자격증명 및 시크릿 관리 전략

애플리케이션이 사용하는 민감한 정보(DB 비밀번호, API 키 등)를 어떻게 관리할 것인가?

**관리 방식 비교**

| 방식 | 저장 위치 | 접근 방식 | 비용 | 보안 수준 |
|------|----------|----------|------|----------|
| **환경 변수 (하드코딩)** | 코드/docker-compose | 직접 참조 | 무료 | ❌ 최악 |
| **GitHub Secrets** | GitHub | Actions에서 주입 | 무료 | ⭐⭐ |
| **.env 파일** | 서버 파일시스템 | 파일 읽기 | 무료 | ⭐⭐ |
| **SSM Parameter Store** | AWS | SDK/CLI로 조회 | 무료~저렴 | ⭐⭐⭐ |
| **AWS Secrets Manager** | AWS | SDK/CLI로 조회 | $0.40/시크릿/월 | ⭐⭐⭐⭐ |
| **HashiCorp Vault** | 자체 운영 | API 조회 | 운영 비용 | ⭐⭐⭐⭐⭐ |

**각 방식 상세**

**1. GitHub Secrets**
```
용도: CI/CD 파이프라인에서 사용하는 시크릿
예시: AWS 인증 정보, SSH 키, Tailscale OAuth

장점:
- GitHub Actions와 자연스럽게 연동
- 무료
- 마스킹 처리

단점:
- 런타임에 애플리케이션이 직접 접근 불가
- GitHub에 저장됨 (신뢰 필요)
- 버전 관리 안됨
```

**2. SSM Parameter Store**
```
용도: 애플리케이션 설정, 덜 민감한 시크릿
예시: DB 호스트, API 엔드포인트, Feature Flag

장점:
- 무료 (Standard 파라미터)
- 계층 구조 지원 (/app/prod/db/host)
- IAM으로 접근 제어
- 버전 히스토리

단점:
- 암호화는 SecureString만 (KMS 키 필요)
- 자동 로테이션 없음
```

**3. AWS Secrets Manager**
```
용도: 고도로 민감한 시크릿
예시: DB 비밀번호, API 키, 인증서

장점:
- 자동 로테이션 지원 (RDS 등)
- 교차 계정 공유 가능
- 감사 로그 (CloudTrail)
- 기본 암호화

단점:
- 비용 발생 ($0.40/시크릿/월)
- Parameter Store보다 복잡
```

**우리의 전략: 하이브리드 접근**

```
┌─────────────────────────────────────────────────────────────────┐
│                    시크릿 관리 전략                              │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  [CI/CD 파이프라인]                                              │
│  └─ GitHub Secrets                                               │
│      ├─ TAILSCALE_CLIENT_ID                                      │
│      ├─ TAILSCALE_CLIENT_SECRET                                  │
│      ├─ SSH_PRIVATE_KEY (Tailscale 백업용)                       │
│      └─ AWS_ROLE_ARN (OIDC용)                                   │
│                                                                  │
│  [애플리케이션 설정]                                              │
│  └─ SSM Parameter Store                                          │
│      ├─ /billage/prod/db/host                                    │
│      ├─ /billage/prod/db/name                                    │
│      ├─ /billage/prod/redis/host                                 │
│      └─ /billage/prod/feature/new-ui-enabled                     │
│                                                                  │
│  [민감한 시크릿]                                                  │
│  └─ AWS Secrets Manager                                          │
│      ├─ billage/prod/db/credentials                              │
│      ├─ billage/prod/jwt/secret                                  │
│      └─ billage/prod/external-api/keys                           │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

**구현 방법: 런타임 시 시크릿 주입**

**방법 1: EC2 시작 시 환경 변수로 주입**
```bash
#!/bin/bash
# /etc/profile.d/secrets.sh

# SSM Parameter Store에서 설정 로드
export DB_HOST=$(aws ssm get-parameter --name /billage/prod/db/host --query 'Parameter.Value' --output text)

# Secrets Manager에서 민감 정보 로드
export DB_PASSWORD=$(aws secretsmanager get-secret-value --secret-id billage/prod/db/credentials --query 'SecretString' --output text | jq -r '.password')
```

**방법 2: Docker Compose에서 동적 로드**
```yaml
# docker-compose.yml
services:
  backend:
    image: billage/backend:latest
    environment:
      - DB_HOST=${DB_HOST}
      - DB_PASSWORD=${DB_PASSWORD}
    entrypoint: ["/bin/sh", "-c", "source /load-secrets.sh && exec java -jar app.jar"]
```

**방법 3: 애플리케이션에서 직접 SDK 사용 (권장)**
```java
// Spring Boot 예시
@Configuration
public class SecretsConfig {

    @Bean
    public DataSource dataSource() {
        // Secrets Manager에서 직접 로드
        SecretsManagerClient client = SecretsManagerClient.create();
        GetSecretValueResponse response = client.getSecretValue(
            GetSecretValueRequest.builder()
                .secretId("billage/prod/db/credentials")
                .build()
        );

        JsonObject secrets = JsonParser.parseString(response.secretString()).getAsJsonObject();

        return DataSourceBuilder.create()
            .url("jdbc:mysql://" + getParameter("/billage/prod/db/host"))
            .username(secrets.get("username").getAsString())
            .password(secrets.get("password").getAsString())
            .build();
    }
}
```

**Terraform으로 시크릿 인프라 구성**
```hcl
# modules/secrets/main.tf

# SSM Parameter Store (설정값)
resource "aws_ssm_parameter" "db_host" {
  name  = "/${var.project_name}/${var.env}/db/host"
  type  = "String"
  value = var.db_host

  tags = {
    Environment = var.env
  }
}

# Secrets Manager (민감 정보)
resource "aws_secretsmanager_secret" "db_credentials" {
  name = "${var.project_name}/${var.env}/db/credentials"

  tags = {
    Environment = var.env
  }
}

resource "aws_secretsmanager_secret_version" "db_credentials" {
  secret_id = aws_secretsmanager_secret.db_credentials.id
  secret_string = jsonencode({
    username = var.db_username
    password = var.db_password
  })
}

# EC2가 시크릿에 접근할 수 있도록 IAM 정책
resource "aws_iam_role_policy" "secrets_access" {
  name = "${var.project_name}-${var.env}-secrets-access"
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
        Resource = "arn:aws:ssm:*:*:parameter/${var.project_name}/${var.env}/*"
      },
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue"
        ]
        Resource = "arn:aws:secretsmanager:*:*:secret:${var.project_name}/${var.env}/*"
      }
    ]
  })
}
```

**시크릿 관리 정책 정리**

| 시크릿 유형 | 저장 위치 | 접근 방식 | 로테이션 |
|------------|----------|----------|---------|
| CI/CD 인증 정보 | GitHub Secrets | GitHub Actions | 수동 |
| 앱 설정 (비민감) | SSM Parameter Store | SDK (런타임) | 불필요 |
| DB 비밀번호 | Secrets Manager | SDK (런타임) | 자동 (RDS) |
| JWT Secret | Secrets Manager | SDK (런타임) | 수동 (90일) |
| 외부 API 키 | Secrets Manager | SDK (런타임) | 수동 |

---

#### 5.3.6 WAF 도입

ALB + WAF 조합으로 웹 애플리케이션 공격을 방어한다.

```hcl
# modules/waf/main.tf
resource "aws_wafv2_web_acl" "main" {
  name        = "${var.project_name}-${var.env}-waf"
  description = "WAF for Billage"
  scope       = "REGIONAL"

  default_action {
    allow {}
  }

  # AWS 관리형 규칙: 알려진 악성 입력 차단
  rule {
    name     = "AWSManagedRulesCommonRuleSet"
    priority = 1

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      sampled_requests_enabled   = true
      cloudwatch_metrics_enabled = true
      metric_name                = "CommonRuleSet"
    }
  }

  # SQL Injection 방어
  rule {
    name     = "AWSManagedRulesSQLiRuleSet"
    priority = 2

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesSQLiRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      sampled_requests_enabled   = true
      cloudwatch_metrics_enabled = true
      metric_name                = "SQLiRuleSet"
    }
  }

  # Rate Limiting
  rule {
    name     = "RateLimitRule"
    priority = 3

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit              = 2000  # 5분당 2000 요청
        aggregate_key_type = "IP"
      }
    }

    visibility_config {
      sampled_requests_enabled   = true
      cloudwatch_metrics_enabled = true
      metric_name                = "RateLimitRule"
    }
  }

  visibility_config {
    sampled_requests_enabled   = true
    cloudwatch_metrics_enabled = true
    metric_name                = "BillageWAF"
  }
}
```

**WAF가 차단하는 공격들**
- SQL Injection
- Cross-Site Scripting (XSS)
- Path Traversal
- Remote Code Execution 시도
- Rate Limit 초과 (DDoS 방어)

---

## 6. 최종 보안 아키텍처

### 6.1 현재 구현된 아키텍처 (2026-02-09)

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        Billage 보안 아키텍처 (현재)                          │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│   ┌───────────────────────────────────────────────────────────────────────┐ │
│   │                     WireGuard VPN (Primary)                            │ │
│   │                     VPN 터널: 10.100.0.0/24                            │ │
│   │                                                                        │ │
│   │   역할별 IP 할당:                                                       │ │
│   │   ├─ DEVOPS   (10.100.0.17-30): Full Access                           │ │
│   │   ├─ BACKEND  (10.100.0.33-46): SSH, MySQL, Spring Boot               │ │
│   │   ├─ FRONTEND (10.100.0.49-62): Web Ports                             │ │
│   │   └─ AIML     (10.100.0.65-78): FastAPI, SSH                          │ │
│   └───────────────────────────────────────────────────────────────────────┘ │
│                                        │                                     │
│                                        ▼                                     │
│  ┌──────────────────────────────────────────────────────────────────────┐   │
│  │                                                                      │   │
│  │  ┌─────────────────┐ ┌─────────────────┐ ┌───────────────────────┐ │   │
│  │  │   Dev VPC       │ │   Prod VPC      │ │   Management VPC      │ │   │
│  │  │  10.0.0.0/16    │ │  10.1.0.0/16    │ │  10.2.0.0/16          │ │   │
│  │  │                 │ │                 │ │                       │ │   │
│  │  │ ┌─────────────┐ │ │ ┌─────────────┐ │ │ [Public Subnet]      │ │   │
│  │  │ │Main Server  │ │ │ │Main Server  │ │ │ ┌─────────────────┐  │ │   │
│  │  │ │FE+BE+DB+AI  │ │ │ │FE+BE+DB+AI  │ │ │ │ VPN Server      │  │ │   │
│  │  │ └─────────────┘ │ │ └─────────────┘ │ │ │ WireGuard+NAT   │  │ │   │
│  │  │                 │ │                 │ │ │ SNAT(Masquerade)│  │ │   │
│  │  │                 │ │                 │ │ └─────────────────┘  │ │   │
│  │  │                 │ │                 │ │ [Private Subnet]     │ │   │
│  │  │                 │ │                 │ │ ┌─────────────────┐  │ │   │
│  │  │                 │ │                 │ │ │ Monitoring      │  │ │   │
│  │  │                 │ │                 │ │ │ Prometheus      │  │ │   │
│  │  │                 │ │                 │ │ │ Grafana, Loki   │  │ │   │
│  │  └────────┬────────┘ └────────┬────────┘ │ └─────────────────┘  │ │   │
│  │           │                   │          └──────────┬───────────┘ │   │
│  │           └───────VPC Peering─┴─────────────────────┘             │   │
│  └──────────────────────────────────────────────────────────────────────┘   │
│                                                                              │
│  접근 경로:                                                                  │
│  ├─ 일반 사용자: Internet → Nginx → App                                    │
│  ├─ 개발자 관리: WireGuard VPN → SSH/DB/Grafana                            │
│  ├─ VPN 장애 시: SSM Session Manager (예정)                                │
│  └─ CI/CD 배포: SSM Run Command (예정)                                      │
│                                                                              │
│  VPC Peering + VPN 라우팅:                                                  │
│  ├─ VPN Client → VPN Server (10.2.1.x) → SNAT → VPC Peering → Dev/Prod   │
│  └─ 응답: Dev/Prod → VPC Peering → VPN Server (10.2.1.x) → VPN Client    │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 6.2 로드맵: 인프라 성장에 따른 보안 진화

```
┌─────────────────────────────────────────────────────────────────────┐
│  Phase 1 (현재)                                                      │
│  ─────────────────                                                   │
│  • Public Subnet + Single Instance                                  │
│  • Tailscale VPN (빠른 도입, 무료)                                   │
│  • GitHub Actions + Tailscale SSH                                   │
│  • SSM 백업 경로                                                     │
│  • GitHub Secrets + SSM Parameter Store                             │
└─────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────┐
│  Phase 2 (3개월 후)                                                  │
│  ─────────────────                                                   │
│  • NACL 추가                                                         │
│  • WAF 도입 (공격 로그 분석 후)                                       │
│  • Secrets Manager 도입 (민감 시크릿)                                │
│  • VPN 안정성 모니터링 체계 구축                                      │
└─────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────┐
│  Phase 3 (6개월+ 후, 인프라 확장 시)                                  │
│  ─────────────────                                                   │
│  • Private Subnet 도입                                               │
│  • Tailscale Subnet Router 또는 AWS Client VPN 검토                 │
│  • Bastion Host 추가 (긴급 접근용)                                   │
│  • CodeDeploy 도입 (다중 인스턴스 배포)                              │
│  • Multi-AZ 구성                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

### 6.2 Security Group 개선안

```hcl
# Main Server SG - 최소 권한
resource "aws_security_group" "main" {
  name = "${var.project_name}-${var.env}-main-sg"

  # HTTPS만 외부 허용
  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # HTTP는 HTTPS 리다이렉트용
  ingress {
    description = "HTTP (redirect to HTTPS)"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # SSH - SSM 사용 시 제거 가능
  # ingress {
  #   from_port   = 22
  #   ...
  # }

  # 내부 포트 (8080, 3000, 5000, 3306) - 외부 노출 제거
  # → localhost 바인딩으로 처리

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
```

### 6.3 개선 전후 비교 (Phase 1 적용 후)

| 항목 | Before | After (Phase 1) | 선택 근거 |
|------|--------|-----------------|----------|
| SSH | 0.0.0.0/0 | Tailscale만 (100.64.0.0/10) | 빠른 도입, 무료 |
| MySQL | Dev: 0.0.0.0/0 | Tailscale만 | DB 직접 접근 필요 |
| Grafana | 0.0.0.0/0 | Tailscale만 | 브라우저 직접 접근 |
| Spring Boot | 0.0.0.0/0 | localhost만 | 외부 노출 제거 |
| FastAPI | 0.0.0.0/0 | localhost만 | 외부 노출 제거 |
| CI/CD 인증 | Access Key | OIDC | 장기 자격증명 제거 |
| 배포 방식 | SSH (변동 IP) | Tailscale + SSH | 간편, 무료 |
| 배포 백업 | 없음 | SSM Run Command | Tailscale 장애 대비 |
| 시크릿 관리 | 환경변수/코드 | Parameter Store + Secrets Manager | 중앙 집중 관리 |
| 개발자 접근 | IP 화이트리스트 | Tailscale 계정 | 화이트리스트 지옥 해결 |
| 접근 감사 | 불가능 | Tailscale 로그 + CloudTrail | 누가 언제 접속했는지 |
| VPN 장애 대응 | N/A | SSM Session Manager | 긴급 접근 경로 |

---

## 7. 마치며

### 7.1 배운 점

1. **보안은 사후가 아닌 사전 대응이다**
   - 공격은 서비스 규모와 상관없이 발생한다
   - 자동화된 봇이 24시간 취약점을 스캔한다
   - 서비스 배포 후 몇 분 만에 공격이 시작된다

2. **"일단 되게 만들자"의 함정**
   - 개발 편의를 위해 열어둔 포트가 공격 표면이 된다
   - Dev 환경도 인터넷에 노출되면 공격받는다
   - "나중에 보안 강화하자"는 말은 대부분 실현되지 않는다

3. **다층 방어(Defense in Depth)의 중요성**
   - Security Group만으로는 부족하다
   - NACL + WAF + 애플리케이션 보안이 모두 필요하다
   - 하나가 뚫려도 다른 계층에서 방어할 수 있어야 한다

4. **현재 상황에 맞는 솔루션을 선택하라**
   - "최고의 솔루션"보다 "우리 상황에 맞는 솔루션"이 중요하다
   - AWS Client VPN이 좋아도 비용이 부담되면 Tailscale이 답
   - CodeDeploy가 강력해도 단일 인스턴스에는 오버스펙
   - 상황이 바뀌면 솔루션도 바꿀 수 있도록 유연하게 설계

5. **장애 대비는 선택이 아니라 필수**
   - Tailscale이 장애나면 서버 접근 불가? → SSM 백업 경로
   - GitHub Actions 장애나면 배포 불가? → 수동 배포 프로세스
   - 단일 경로에 의존하면 그 경로가 SPOF가 된다

6. **자격증명 관리의 어려움**
   - 장기 자격증명(Access Key, SSH Key)은 관리 부담이 크다
   - OIDC, SSM 같은 단기 토큰 방식으로 전환해야 한다
   - 시크릿은 코드가 아닌 전용 저장소(Secrets Manager)에
   - OIDC 같은 현대적인 방식으로 전환해야 한다

### 7.2 앞으로의 계획 (2026-02-09 업데이트)

**Phase 1: 인프라 구축 - 완료 ✅**
- [x] 보안 취약점 분석 및 문서화
- [x] Management VPC 구축 (VPN 서버 + 중앙 모니터링)
- [x] WireGuard VPN 서버 구축 (Primary VPN)
- [x] VPC Peering 설정 (Dev ↔ Management, Prod ↔ Management)
- [x] 중앙 집중식 모니터링 구축 (Private Subnet)
- [x] 역할별 VPN 사용자 등록 (DEVOPS, BACKEND, FRONTEND, AIML)

**Phase 1.5: VPN 접근 제어 - 완료 ✅**
- [x] WireGuard VPN 서버 운영 중
- [x] 역할별 IP 할당 정책 적용
- [x] Security Group 수정: SSH/DB → VPN CIDR만 허용
- [x] VPC Peering 라우팅 문제 분석 및 해결 (SNAT/Masquerade 필요)

**Phase 2: 단기 개선 (진행 중)**
- [ ] VPN 서버 Masquerade 규칙 적용 (VPC Peering 라우팅 해결)
- [ ] iptables 역할별 필터링 적용
- [ ] 애플리케이션 포트 내부화 (8080, 3000, 5000 → localhost)
- [ ] SSM 백업 경로 구성
- [ ] GitHub Actions OIDC 전환 (Access Key 제거)

**Phase 3: 중기 개선 (예정)**
- [ ] SSM Parameter Store로 설정값 이관
- [ ] Secrets Manager로 민감 시크릿 이관
- [ ] NACL 구성
- [ ] WAF 도입 검토 (공격 패턴 분석 후)
- [ ] Private Subnet 도입 검토 (인프라 확장 시)

### 7.3 마지막으로

> "보안에 100%란 없다. 하지만 공격자보다 한 발 앞서 있을 수는 있다."

이 문서가 같은 고민을 하는 개발자들에게 도움이 되길 바란다.

---

## 부록

### A. 참고 자료

- [AWS Security Best Practices](https://docs.aws.amazon.com/wellarchitected/latest/security-pillar/welcome.html)
- [OWASP Top 10](https://owasp.org/www-project-top-ten/)
- [GitHub Actions OIDC](https://docs.github.com/en/actions/deployment/security-hardening-your-deployments/configuring-openid-connect-in-amazon-web-services)
- [AWS WAF Managed Rules](https://docs.aws.amazon.com/waf/latest/developerguide/aws-managed-rule-groups.html)

### B. 공격 로그 원본

```log
43.166.224.244 - - [29/Jan/2026:00:04:01 +0900] "GET / HTTP/1.1" 200 2216
216.81.245.109 - - [29/Jan/2026:00:19:36 +0900] "GET /.git/config HTTP/1.1" 404 2254
98.88.247.68 - - [29/Jan/2026:00:29:31 +0900] "GET /?s=/Index/\x5Cthink\x5Capp/invokefunction&function=call_user_func_array&vars[0]=system&vars[1][]=printenv HTTP/1.1" 200 2216
98.88.247.68 - - [29/Jan/2026:00:29:33 +0900] "GET /_ignition/health-check HTTP/1.1" 404 2254
98.88.247.68 - - [29/Jan/2026:00:29:37 +0900] "GET /actuator/env HTTP/1.1" 404 2254
```

### C. 용어 정리

| 용어 | 설명 |
|------|------|
| Security Group | AWS의 인스턴스 레벨 가상 방화벽 |
| NACL | Network Access Control List, 서브넷 레벨 방화벽 |
| WAF | Web Application Firewall, L7 방화벽 |
| OIDC | OpenID Connect, 토큰 기반 인증 프로토콜 |
| SSM | AWS Systems Manager, 인스턴스 관리 서비스 |
| SSM Parameter Store | AWS 설정값 저장소, 무료 |
| Secrets Manager | AWS 민감 정보 저장소, 자동 로테이션 지원 |
| VPN | Virtual Private Network, 가상 사설 네트워크 |
| Site-to-Site VPN | 네트워크와 네트워크를 연결하는 VPN |
| Client-to-Site VPN | 개인 PC에서 네트워크로 접속하는 VPN |
| Tailscale | WireGuard 기반 메시 VPN 서비스, 설치 간편 |
| WireGuard | 최신 VPN 프로토콜, 고성능, 오픈소스 |
| AWS Client VPN | AWS 관리형 VPN 서비스, OpenVPN 기반 |
| Bastion Host | SSH 접근을 위한 중간 서버 (Jump Server) |
| Self-hosted Runner | GitHub Actions를 자체 인프라에서 실행하는 방식 |
| SSM Run Command | SSM을 통해 원격으로 명령 실행하는 기능 |
| CodeDeploy | AWS 배포 서비스, 롤백/배포 전략 지원 |
| Split Tunnel | VPN 연결 시 특정 트래픽만 VPN 경유하는 방식 |
| Subnet Router | Tailscale에서 서브넷 전체를 라우팅하는 기능 |
| CGNAT | Carrier-Grade NAT, 100.64.0.0/10 대역 |
| CLOSE_WAIT | TCP 연결 종료 대기 상태 |
| RCE | Remote Code Execution, 원격 코드 실행 |
| SPOF | Single Point of Failure, 단일 장애점 |
| 화이트리스트 지옥 | IP 기반 접근 제어의 관리 복잡성 문제 |

---

*문서 작성일: 2026-02-02*
*최종 수정일: 2026-02-09*
*작성자: Billage 인프라팀*
