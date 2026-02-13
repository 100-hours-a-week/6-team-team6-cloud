# shared/acm/variables.tf

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

variable "domain_name" {
  description = "Route 53 도메인"
  type        = string
  default     = "billages.com"
}
