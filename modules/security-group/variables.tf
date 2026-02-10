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

#==============================================================================
# VPN 역할별 CIDR 대역 설정 (Pure Routing용)
# Management VPC CIDR(10.2.0.0/16) 내부 대역 사용 - VPC Peering 호환
# 역할별 CIDR 대역:
#   System:   10.100.0.0/28  (.1 VPN Server)
#   DevOps:   10.100.0.16/28 (.17 ~ .30)
#   Backend:  10.100.0.32/28 (.33 ~ .46)
#   Frontend: 10.100.0.48/28 (.49 ~ .62)
#   AI/ML:    10.100.0.64/28 (.65 ~ .78)
#==============================================================================
variable "enable_vpn_role_based_access" {
  description = "역할별 VPN IP 기반 접근 제어 활성화"
  type        = bool
  default     = false
}

variable "vpn_devops_cidr" {
  description = "DevOps Team VPN CIDR - SSH (All), 전체 서비스 접근"
  type        = string
  default     = "10.100.0.16/28"
}

variable "vpn_backend_cidr" {
  description = "Backend Team VPN CIDR - SSH (App), MySQL 접근"
  type        = string
  default     = "10.100.0.32/28"
}

variable "vpn_frontend_cidr" {
  description = "Frontend Team VPN CIDR - Web Port (80, 443, 3000) 접근"
  type        = string
  default     = "10.100.0.48/28"
}

variable "vpn_ai_ml_cidr" {
  description = "AI/ML Team VPN CIDR - FastAPI, GPU Server 접근"
  type        = string
  default     = "10.100.0.64/28"
}
