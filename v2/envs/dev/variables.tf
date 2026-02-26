# v2/envs/dev/variables.tf
# Billage v2 Dev 환경 변수

#==============================================================================
# 기본 설정
#==============================================================================
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
  description = "환경 (dev/prod)"
  type        = string
  default     = "dev"
}

variable "domain_name" {
  description = "Route 53 도메인"
  type        = string
  default     = "billages.com"
}

#==============================================================================
# 네트워크 설정
# Private Subnets (RDS용)은 shared/rds/dev에서 생성
#==============================================================================
variable "public_subnet_cidr_c" {
  description = "Public Subnet CIDR (AZ-c) - ALB용"
  type        = string
  default     = "10.0.2.0/24"
}

variable "private_subnet_cidr_a" {
  description = "Private Subnet CIDR (AZ-a) - EC2용"
  type        = string
  default     = "10.0.20.0/24"
}

variable "private_subnet_cidr_c" {
  description = "Private Subnet CIDR (AZ-c) - EC2용"
  type        = string
  default     = "10.0.21.0/24"
}

variable "management_vpc_cidr" {
  description = "Management VPC CIDR (VPC Peering 라우팅용)"
  type        = string
  default     = "10.2.0.0/16"
}

variable "vpn_cidr" {
  description = "VPN CIDR (WireGuard)"
  type        = list(string)
  default     = ["10.100.0.0/24"]
}

#==============================================================================
# EC2 공통 설정
#==============================================================================
variable "golden_ami_id" {
  description = "Golden AMI ID"
  type        = string
  # default = "ami-01488502d83cfffa4" # terraform.tfvars에서 설정
}

variable "app_root_volume_size" {
  description = "루트 볼륨 크기 (GB)"
  type        = number
  default     = 20
}

variable "key_name" {
  description = "EC2 키페어 이름"
  type        = string
  default     = "billage-keypair"
}

#==============================================================================
# Backend ASG 설정
#==============================================================================
variable "backend_instance_type" {
  description = "Backend 인스턴스 타입"
  type        = string
  default     = "t3.small" # 2 vCPU, 2GB (x86_64)
}

variable "backend_asg_desired" {
  description = "Backend ASG 희망 인스턴스 수"
  type        = number
  default     = 1
}

variable "backend_asg_min" {
  description = "Backend ASG 최소 인스턴스 수"
  type        = number
  default     = 1
}

variable "backend_asg_max" {
  description = "Backend ASG 최대 인스턴스 수"
  type        = number
  default     = 1 # Dev: 스케일아웃 비활성화
}

#==============================================================================
# Frontend ASG 설정
#==============================================================================
variable "frontend_instance_type" {
  description = "Frontend 인스턴스 타입"
  type        = string
  default     = "t3.small" # 2 vCPU, 2GB (x86_64)
}

variable "frontend_asg_desired" {
  description = "Frontend ASG 희망 인스턴스 수"
  type        = number
  default     = 1
}

variable "frontend_asg_min" {
  description = "Frontend ASG 최소 인스턴스 수"
  type        = number
  default     = 1
}

variable "frontend_asg_max" {
  description = "Frontend ASG 최대 인스턴스 수"
  type        = number
  default     = 1 # Dev: 스케일아웃 비활성화
}

#==============================================================================
# AI ASG 설정
#==============================================================================
variable "ai_instance_type" {
  description = "AI 인스턴스 타입"
  type        = string
  default     = "t3.small" # 2 vCPU, 2GB (x86_64)
}

variable "ai_asg_desired" {
  description = "AI ASG 희망 인스턴스 수"
  type        = number
  default     = 1
}

variable "ai_asg_min" {
  description = "AI ASG 최소 인스턴스 수"
  type        = number
  default     = 1
}

variable "ai_asg_max" {
  description = "AI ASG 최대 인스턴스 수"
  type        = number
  default     = 1 # Dev: 스케일아웃 비활성화
}

#==============================================================================
# Health Check 설정
#==============================================================================
variable "backend_health_check_path" {
  description = "Backend 헬스체크 경로"
  type        = string
  default     = "/actuator/health"
}

variable "ai_health_check_path" {
  description = "AI 서버 헬스체크 경로"
  type        = string
  default     = "/health"
}
