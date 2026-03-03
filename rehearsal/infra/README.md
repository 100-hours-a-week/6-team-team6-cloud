# Rehearsal Simple v2 Infra

## 근본 목적
기존 인프라/모듈을 수정하지 않고, 리허설용 ALB + BE ASG + RDS를 최소 구성으로 빠르게 생성/운영 확인한다.

## 비목적
- 기존 운영 환경(v2 prod/dev) 구조 변경
- DNS/도메인 전략 전면 이전 설계
- 공유 모듈(`modules/*`) 리팩토링

이 디렉터리는 리허설용으로만 쓰는 최소 Terraform 구성입니다.

- `main.tf` : ALB, Backend ASG, RDS(MySQL), IAM, SG, Route53(옵션)
- `variables.tf` : 재사용 가능한 변수 정의
- `outputs.tf` : 운영 체크 포인트
- `user_data_backend.sh.tpl` : backend 인스턴스 bootstrap

## 실행

```bash
cd rehearsal/infra
cp terraform.tfvars.example terraform.tfvars
# 값 입력 후
terraform init
terraform plan -out rehearsal.plan
terraform apply rehearsal.plan
```

## 확인
- ALB listener: 8081
- Backend 컨테이너 포트: 8080
- ALB → 백엔드 TG/ASG/Target Health는 `terraform output` + `migration/infra/rehearsal-verify.sh`로 점검

## 주의
- 기존 리소스는 수정하지 않고 새롭게 생성합니다.
- `create_dns_record`는 기본 false입니다. 필요한 경우에만 true로 설정하세요.
