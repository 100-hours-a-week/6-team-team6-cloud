# shared/rabbitmq/prod/variables.tf

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
  default     = "prod"
}

variable "instance_type" {
  description = "RabbitMQ EC2 인스턴스 타입"
  type        = string
  default     = "t3.small"
}

variable "root_volume_size" {
  description = "RabbitMQ 루트 볼륨 크기(GB)"
  type        = number
  default     = 20
}

variable "key_name" {
  description = "운영 접근용 키페어 이름"
  type        = string
  default     = "billage-keypair"
}

variable "rabbitmq_username" {
  description = "RabbitMQ 기본 사용자명"
  type        = string
  default     = "billage"
}

variable "management_access_cidrs" {
  description = "RabbitMQ Management UI(15672) 접근 허용 CIDR"
  type        = list(string)
  default     = ["10.2.0.0/16", "10.100.0.16/28"]
}

variable "v1_state_bucket" {
  description = "v1 Prod remote state bucket"
  type        = string
  default     = "billage-terraform-state-prod"
}

variable "v1_state_key" {
  description = "v1 Prod remote state key"
  type        = string
  default     = "prod/terraform.tfstate"
}

variable "v1_state_lock_table" {
  description = "v1 Prod remote state lock table"
  type        = string
  default     = "billage-terraform-lock-prod"
}

variable "v2_state_bucket" {
  description = "v2 Prod remote state bucket"
  type        = string
  default     = "billage-terraform-state-prod"
}

variable "v2_state_key" {
  description = "v2 Prod remote state key"
  type        = string
  default     = "v2/prod/terraform.tfstate"
}

variable "v2_state_lock_table" {
  description = "v2 Prod remote state lock table"
  type        = string
  default     = "billage-terraform-lock-prod"
}
