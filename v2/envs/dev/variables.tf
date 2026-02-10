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

#==============================================================================
# VPC 설정
#==============================================================================
variable "vpc_cidr" {
  description = "VPC CIDR 블록"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "Public Subnet CIDR 블록 (Multi-AZ)"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "private_subnet_cidrs" {
  description = "Private Subnet CIDR 블록 (Multi-AZ)"
  type        = list(string)
  default     = ["10.0.11.0/24", "10.0.12.0/24"]
}

variable "availability_zones" {
  description = "사용할 가용 영역"
  type        = list(string)
  default     = ["ap-northeast-2a", "ap-northeast-2c"]
}

#==============================================================================
# RDS 설정
#==============================================================================
variable "rds_instance_class" {
  description = "RDS 인스턴스 타입"
  type        = string
  default     = "db.t4g.medium"
}

#==============================================================================
# ASG 설정
#==============================================================================
variable "backend_min_size" {
  description = "Backend ASG 최소 인스턴스 수"
  type        = number
  default     = 2
}

variable "backend_max_size" {
  description = "Backend ASG 최대 인스턴스 수"
  type        = number
  default     = 6
}

#==============================================================================
# 도메인 설정
#==============================================================================
variable "domain_name" {
  description = "Route 53 도메인"
  type        = string
  default     = "billages.com"
}