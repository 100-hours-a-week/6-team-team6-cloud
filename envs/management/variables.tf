# envs/management/variables.tf
# Management 환경 변수 정의

#==============================================================================
# 공통 설정
#==============================================================================
variable "project_name" {
  description = "프로젝트 이름"
  type        = string
  default     = "billage"
}

variable "env" {
  description = "환경"
  type        = string
  default     = "management"
}

variable "aws_region" {
  description = "AWS 리전"
  type        = string
  default     = "ap-northeast-2"  # 서울
}

#==============================================================================
# VPC 설정
# CIDR 할당: dev=10.0.0.0/16, prod=10.1.0.0/16, management=10.2.0.0/16
#==============================================================================
variable "vpc_cidr" {
  description = "Management VPC CIDR 블록"
  type        = string
  default     = "10.2.0.0/16"
}

variable "public_subnet_cidr" {
  description = "Public Subnet CIDR (VPN 서버)"
  type        = string
  default     = "10.2.1.0/24"
}

variable "private_subnet_cidr" {
  description = "Private Subnet CIDR (모니터링 서버)"
  type        = string
  default     = "10.2.2.0/24"
}

variable "availability_zone" {
  description = "가용 영역 (단일 AZ, 비용 최적화)"
  type        = string
  default     = "ap-northeast-2a"
}

#==============================================================================
# EC2 설정
#==============================================================================
variable "monitoring_instance_type" {
  description = "모니터링 서버 EC2 타입 (ARM) - Prometheus/Grafana/Loki"
  type        = string
  default     = "t4g.small"  # 2 vCPU, 2GB RAM (swap으로 보완)
}

variable "vpn_instance_type" {
  description = "VPN 서버 EC2 타입 (ARM) - WireGuard + NAT instance"
  type        = string
  default     = "t4g.micro"  # 2 vCPU, 1GB RAM (arm64 AMI 호환, t3.micro 대체)
}

variable "monitoring_root_volume_size" {
  description = "모니터링 서버 볼륨 크기 (GB) - Prometheus/Loki 데이터 저장 고려"
  type        = number
  default     = 40
}

variable "vpn_root_volume_size" {
  description = "VPN 서버 볼륨 크기 (GB)"
  type        = number
  default     = 20
}

#==============================================================================
# 키페어 설정
#==============================================================================
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

#==============================================================================
# Security Group 설정
#==============================================================================
variable "ssh_allowed_cidr" {
  description = "VPN 서버 SSH 접근 허용 CIDR (운영 시 특정 IP 제한 권장)"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "monitoring_admin_cidr" {
  description = "모니터링 UI 접근 허용 CIDR (Grafana, Prometheus) - WireGuard 터널 + VPC 내부"
  type        = list(string)
  default     = ["10.100.0.0/24", "10.2.0.0/16"]  # WireGuard 터널 서브넷 + Management VPC
}
