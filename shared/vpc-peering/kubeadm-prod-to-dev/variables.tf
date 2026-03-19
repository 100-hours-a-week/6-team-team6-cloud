# shared/vpc-peering/kubeadm-prod-to-dev/variables.tf

variable "aws_region" {
  description = "AWS 리전"
  type        = string
  default     = "ap-northeast-2"
}

variable "project_name" {
  description = "프로젝트 이름"
  type        = string
  default     = "billage"
}

#==============================================================================
# VPC IDs & CIDRs
#==============================================================================
variable "kubeadm_prod_vpc_id" {
  description = "kubeadm-prod VPC ID"
  type        = string
}

variable "kubeadm_prod_vpc_cidr" {
  description = "kubeadm-prod VPC CIDR"
  type        = string
  default     = "10.30.0.0/16"
}

variable "dev_vpc_id" {
  description = "dev VPC ID"
  type        = string
}

variable "dev_vpc_cidr" {
  description = "dev VPC CIDR"
  type        = string
  default     = "10.0.0.0/16"
}

#==============================================================================
# Route Table IDs
#==============================================================================
variable "kubeadm_prod_route_table_ids" {
  description = "kubeadm-prod VPC의 라우트 테이블 ID 목록 (dev 방향 라우트 추가 대상)"
  type        = list(string)
}

variable "dev_route_table_ids" {
  description = "dev VPC의 라우트 테이블 ID 목록 (kubeadm-prod 방향 라우트 추가 대상)"
  type        = list(string)
}

#==============================================================================
# Security Group IDs (dev VPC - 인바운드 규칙 추가 대상)
#==============================================================================
variable "dev_rds_sg_id" {
  description = "dev RDS Security Group ID"
  type        = string
}

variable "dev_kafka_sg_id" {
  description = "dev Kafka Security Group ID"
  type        = string
}

variable "dev_rabbitmq_sg_id" {
  description = "dev RabbitMQ Security Group ID"
  type        = string
}

variable "dev_qdrant_sg_id" {
  description = "dev Qdrant Security Group ID"
  type        = string
}
