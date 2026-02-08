# modules/security-group/variables.tf

variable "project_name" {
  description = "프로젝트 이름"
  type        = string
}

variable "env" {
  description = "환경 (dev, prod)"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID"
  type        = string
}

variable "vpc_cidr" {
  description = "VPC CIDR 블록"
  type        = string
}

variable "ssh_allowed_cidr" {
  description = "SSH 접근 허용 CIDR (보안을 위해 특정 IP 권장)"
  type        = list(string)
  default     = ["0.0.0.0/0"]  # 개발 단계에서는 전체 허용, 운영 시 특정 IP로 제한
}

variable "db_allowed_cidr" {
  description = "DB 접근 허용 CIDR"
  type        = list(string)
  default     = ["0.0.0.0/0"]  # 개발 단계, 운영 시 VPC CIDR로 제한 권장
}

variable "monitoring_allowed_cidr" {
  description = "Monitoring UI 접근 허용 CIDR (Grafana, Prometheus)"
  type        = list(string)
  default     = ["0.0.0.0/0"]  # 개발 단계, 운영 시 관리자 IP로 제한 권장
}

#==============================================================================
# Tailscale VPN 설정
#==============================================================================
variable "enable_tailscale" {
  description = "Tailscale VPN 사용 여부 - true일 경우 SSH/DB/Monitoring 접근을 Tailscale 네트워크로 제한"
  type        = bool
  default     = false
}

variable "tailscale_cidr" {
  description = "Tailscale VPN CIDR (CGNAT 대역)"
  type        = string
  default     = "100.64.0.0/10"
}

variable "management_scrape_cidr" {
  description = "Management VPC Prometheus 접근 허용 CIDR"
  type        = list(string)
  default     = []
}
