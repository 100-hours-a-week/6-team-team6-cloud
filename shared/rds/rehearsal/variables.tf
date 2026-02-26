# shared/rds/rehearsal/variables.tf

variable "aws_region" {
  description = "AWS Region"
  type        = string
  default     = "ap-northeast-2"
}

variable "project_name" {
  description = "프로젝트 이름"
  type        = string
  default     = "billage"
}

variable "env" {
  description = "환경"
  type        = string
  default     = "dev"
}

#==============================================================================
# 네트워크 설정
#==============================================================================
variable "private_subnet_cidr_a" {
  description = "Private Subnet CIDR (AZ-a)"
  type        = string
  default     = "10.0.10.0/24"
}

variable "private_subnet_cidr_c" {
  description = "Private Subnet CIDR (AZ-c)"
  type        = string
  default     = "10.0.11.0/24"
}

#==============================================================================
# RDS 설정
#==============================================================================
variable "instance_class" {
  description = "RDS 인스턴스 타입"
  type        = string
  default     = "db.t4g.micro"
}

variable "allocated_storage" {
  description = "초기 스토리지 (GB)"
  type        = number
  default     = 20
}

variable "max_allocated_storage" {
  description = "최대 스토리지 (GB) - Auto Scaling"
  type        = number
  default     = 50
}

variable "multi_az" {
  description = "Multi-AZ 배포"
  type        = bool
  default     = false # Dev는 Single-AZ
}

variable "db_name" {
  description = "데이터베이스 이름"
  type        = string
  default     = "billage"
}

variable "username" {
  description = "마스터 사용자명"
  type        = string
  default     = "billage_admin"
}

variable "password" {
  description = "마스터 비밀번호"
  type        = string
  sensitive   = true
}

variable "deletion_protection" {
  description = "삭제 보호"
  type        = bool
  default     = false # Dev는 비활성화
}

variable "skip_final_snapshot" {
  description = "최종 스냅샷 스킵"
  type        = bool
  default     = true # Dev는 스킵
}
