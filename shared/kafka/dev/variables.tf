# shared/kafka/dev/variables.tf

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

variable "instance_type" {
  description = "Kafka EC2 인스턴스 타입"
  type        = string
  default     = "t3.small"
}

variable "root_volume_size" {
  description = "Kafka 루트 볼륨 크기(GB)"
  type        = number
  default     = 30
}

variable "key_name" {
  description = "운영 접근용 키페어 이름"
  type        = string
  default     = "billage-keypair"
}

variable "management_access_cidrs" {
  description = "관리 접근 허용 CIDR (VPN/Management)"
  type        = list(string)
  default     = ["10.2.0.0/16", "10.100.0.16/28"]
}

variable "v2_state_bucket" {
  description = "v2 Dev remote state bucket"
  type        = string
  default     = "billage-terraform-state-dev"
}

variable "v2_state_key" {
  description = "v2 Dev remote state key"
  type        = string
  default     = "v2/dev/terraform.tfstate"
}

variable "v2_state_lock_table" {
  description = "v2 Dev remote state lock table"
  type        = string
  default     = "billage-terraform-lock-dev"
}