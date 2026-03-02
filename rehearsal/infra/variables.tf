# rehearsal/infra/variables.tf
# Rehearsal simple infra (ALB + BE ASG + RDS)

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "ap-northeast-2"
}

variable "project_name" {
  description = "프로젝트 이름"
  type        = string
  default     = "billage"
}

variable "env" {
  description = "리허설 환경 라벨"
  type        = string
  default     = "rehearsal"
}

variable "base_vpc_env" {
  description = "기반 VPC 환경(dev/prod). 기존 네트워크 태그 참조용"
  type        = string
  default     = "dev"
}

variable "domain_name" {
  description = "Route53 zone name (옵션 레코드 생성 시 사용)"
  type        = string
  default     = "billages.com"
}

variable "create_dns_record" {
  description = "기존 Route53에 리허설 레코드 생성 여부"
  type        = bool
  default     = false
}

variable "dns_record_name" {
  description = "ALB 별칭 레코드 이름 (예: rehearsal-api)"
  type        = string
  default     = "rehearsal-api"
}

variable "public_subnet_b_cidr" {
  description = "추가 퍼블릭 서브넷 CIDR (AZ-c)"
  type        = string
  default     = "10.0.3.0/24"
}

variable "public_subnet_b_az" {
  description = "추가 퍼블릭 서브넷 AZ 접미사"
  type        = string
  default     = "c"
}

variable "ssh_allowed_cidr" {
  description = "Backend SSH 허용 CIDR"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

#==============================================================================
# EC2/BE 설정
#==============================================================================
variable "golden_ami_id" {
  description = "Backend EC2에 사용할 AMI ID"
  type        = string
}

variable "key_name" {
  description = "키페어 이름"
  type        = string
  default     = "billage-keypair"
}

variable "app_root_volume_size" {
  description = "루트 볼륨 크기(GB)"
  type        = number
  default     = 20
}

variable "backend_instance_type" {
  description = "Backend 인스턴스 타입"
  type        = string
  default     = "t2.micro"
}

variable "backend_asg_desired" {
  description = "Backend ASG desired"
  type        = number
  default     = 1
}

variable "backend_asg_min" {
  description = "Backend ASG min"
  type        = number
  default     = 1
}

variable "backend_asg_max" {
  description = "Backend ASG max"
  type        = number
  default     = 1
}

variable "backend_health_check_path" {
  description = "Backend ALB health-check path"
  type        = string
  default     = "/actuator/health"
}

variable "backend_service_name" {
  description = "SSM/태그에서 쓰는 backend 서비스명"
  type        = string
  default     = "be"
}

variable "backend_container_image" {
  description = "비워두면 ecr://<project>-be:<env>-latest 사용"
  type        = string
  default     = ""
}

variable "backend_container_port" {
  description = "Backend 컨테이너 포트"
  type        = number
  default     = 8080
}

variable "backend_spring_profile" {
  description = "Spring profile for rehearsal BE runtime"
  type        = string
  default     = "dev"
}

variable "ssm_backend_path" {
  description = "Backend 컨테이너 환경변수 SSM path"
  type        = string
  default     = "/billage/dev/be/"
}

#==============================================================================
# RDS 설정
#==============================================================================
variable "rds_identifier" {
  description = "리허설 RDS 인스턴스 식별자"
  type        = string
  default     = "billage-rehearsal-mysql"
}

variable "rds_engine_version" {
  description = "MySQL 엔진 버전"
  type        = string
  default     = "8.0"
}

variable "rds_instance_class" {
  description = "RDS 인스턴스 스펙"
  type        = string
  default     = "db.t4g.micro"
}

variable "rds_allocated_storage" {
  description = "RDS 초기 스토리지(GB)"
  type        = number
  default     = 20
}

variable "rds_max_allocated_storage" {
  description = "RDS 최대 스토리지 자동 스케일(GB)"
  type        = number
  default     = 100
}

variable "rds_multi_az" {
  description = "Multi-AZ 사용 여부"
  type        = bool
  default     = false
}

variable "rds_publicly_accessible" {
  description = "RDS public 접근 사용 여부 (권장 false)"
  type        = bool
  default     = false
}

variable "rds_db_name" {
  description = "초기 생성 DB명"
  type        = string
  default     = "billage"
}

variable "rds_username" {
  description = "RDS 마스터 사용자명"
  type        = string
  default     = "billage_admin"
}

variable "rds_password" {
  description = "RDS 마스터 비밀번호"
  type        = string
  sensitive   = true
}

variable "rds_deletion_protection" {
  description = "RDS 삭제 방지"
  type        = bool
  default     = false
}

variable "rds_skip_final_snapshot" {
  description = "삭제 시 최종 스냅샷 생략"
  type        = bool
  default     = true
}

variable "rds_backup_retention_days" {
  description = "백업 보존 일수"
  type        = number
  default     = 7
}
