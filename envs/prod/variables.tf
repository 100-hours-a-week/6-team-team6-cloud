# envs/prod/variables.tf
# 변수 정의

#==============================================================================
# 공통 설정
#==============================================================================
variable "project_name" {
  description = "프로젝트 이름"
  type        = string
  default     = "billage"
}

variable "env" {
  description = "환경 (dev, prod)"
  type        = string
  default     = "prod"
}

variable "aws_region" {
  description = "AWS 리전"
  type        = string
  default     = "ap-northeast-2"  # 서울
}

#==============================================================================
# VPC 설정
#==============================================================================
variable "vpc_cidr" {
  description = "VPC CIDR 블록"
  type        = string
  default     = "10.1.0.0/16"
}

variable "public_subnet_cidr" {
  description = "Public Subnet CIDR 블록"
  type        = string
  default     = "10.1.1.0/24"
}

variable "availability_zone" {
  description = "가용 영역"
  type        = string
  default     = "ap-northeast-2a"
}

#==============================================================================
# Security Group 설정
#==============================================================================
variable "ssh_allowed_cidr" {
  description = "SSH 접근 허용 CIDR (보안을 위해 특정 IP 권장)"
  type        = list(string)
  default     = ["0.0.0.0/0"]  # 운영 시 특정 IP로 제한 권장
}

variable "db_allowed_cidr" {
  description = "DB 접근 허용 CIDR"
  type        = list(string)
  default     = ["10.1.0.0/16"]  # 운영: VPC 내부만 허용
}

#==============================================================================
# EC2 설정
#==============================================================================
variable "instance_type" {
  description = "EC2 인스턴스 타입"
  type        = string
  default     = "t4g.medium"  # ARM 기반, 2 vCPU, 4GB RAM, 월 약 3.4만원
}

variable "root_volume_size" {
  description = "루트 볼륨 크기 (GB)"
  type        = number
  default     = 30
}

variable "create_key_pair" {
  description = "새로운 키페어 생성 여부"
  type        = bool
  default     = false
}

variable "public_key" {
  description = "SSH 공개 키 (create_key_pair가 true일 때 필요)"
  type        = string
  default     = ""
}

variable "existing_key_name" {
  description = "기존 키페어 이름 (create_key_pair가 false일 때 필요)"
  type        = string
  default     = ""
}

variable "create_eip" {
  description = "Elastic IP 생성 여부"
  type        = bool
  default     = true
}