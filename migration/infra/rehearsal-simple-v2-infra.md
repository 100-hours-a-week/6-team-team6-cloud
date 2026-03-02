# Rehearsal Simple v2 인프라 실행 가이드

## 근본 목적
기존 리허설 코드를 건드리지 않고, 새 브랜치 기반으로 `rehearsal/infra`와 `migration/infra` 산출물만으로
ALB + BE ASG + RDS 단일 스택을 빠르게 생성/검증해 리허설 실습을 진행한다.

## 비목적
- 기존 운영/기존 v2 모듈의 리팩토링
- `shared` 모듈 및 기존 인프라 리소스의 구조 변경
- 서비스/도메인 전면 이전

목표: 기존 리허설 산출물과 독립적으로, 새 브랜치의 `rehearsal/infra`로
`ALB + BE ASG + RDS`를 한 번에 구성한다.

## 생성 범위
- VPC 재사용: 기존 `${project_name}-${base_vpc_env}-vpc` 사용
- 퍼블릭 서브넷 2개(기존 public-a + 새 public-b)로 ALB/ASG 배치
- Backend ASG(단일) + Target Group + Listener(8081)
- RDS(MySQL) 단일 인스턴스
- DNS 레코드는 `create_dns_record`가 true일 때만 생성

## 실행 순서 (로컬)

1. 브랜치 확인
   - `git status`로 현재 브랜치가 `feat/rehearsal-simple-v2-infra`인지 확인
2. tfvars 준비
   - `cp rehearsal/infra/terraform.tfvars.example rehearsal/infra/terraform.tfvars`
   - `rds_password`, `golden_ami_id` 반드시 입력
3. 초기화 및 계획 생성
   - `cd rehearsal/infra`
   - `terraform init`
   - `terraform plan -out rehearsal.plan`
4. 적용
   - `terraform apply rehearsal.plan`
5. 결과 확인
   - `terraform output`
   - `terraform output -raw alb_http8081_endpoint`
   - `terraform output -raw rds_endpoint`

## 점검 포인트 (리허설용 최소 체크)

- ALB DNS: 출력 `alb_http8081_endpoint`로 접속되어야 함
- ASG 상태: `aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names <backend_asg_name>`
- Target Health: `aws elbv2 describe-target-health --target-group-arn <backend_tg_arn>`
- RDS 상태: `aws rds describe-db-instances --db-instance-identifier <rds_identifier>`
- 앱 포트 매핑: ALB 리스너는 8081, 컨테이너는 8080

## 기존 리허설 소스(8081)와 연결할 때
- 기존 nginx/upstream에서 `http://<ALB_DNS>:8081`로 지정하면 된다.
- 이 스택은 80 요청을 8081로 리다이렉트한다.
- 리허설용엔드포인트를 바꾸는 경우: `terraform.tfvars`에서 `dns_record_name`을 바꾸고
  `create_dns_record = true`로 재적용.

## 롤백/정리
- `terraform destroy`로 해당 스택만 정리
- RDS 삭제 전 스냅샷/DB 보호 설정을 다시 점검
