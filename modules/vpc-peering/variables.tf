# modules/vpc-peering/variables.tf

variable "project_name" {
  description = "프로젝트 이름"
  type        = string
}

variable "env" {
  description = "요청측 환경 식별자"
  type        = string
}

variable "peer_name" {
  description = "피어링 대상 환경 이름 (예: dev, prod)"
  type        = string
}

variable "requester_vpc_id" {
  description = "요청측 VPC ID"
  type        = string
}

variable "requester_vpc_cidr" {
  description = "요청측 VPC CIDR"
  type        = string
}

variable "accepter_vpc_id" {
  description = "수락측 VPC ID"
  type        = string
}

variable "accepter_vpc_cidr" {
  description = "수락측 VPC CIDR"
  type        = string
}

variable "requester_route_table_ids" {
  description = "요청측 라우팅 테이블 ID 목록 (피어 방향 라우트 추가 대상)"
  type        = list(string)
}

variable "accepter_route_table_ids" {
  description = "수락측 라우팅 테이블 ID 목록 (피어 방향 라우트 추가 대상)"
  type        = list(string)
}

variable "vpn_cidr" {
  description = "WireGuard VPN CIDR (Pure Routing용 - Dev/Prod에서 VPN 클라이언트로 응답 라우팅)"
  type        = string
  default     = ""
}
