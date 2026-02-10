# shared/ssm/variables.tf

variable "aws_region" {
  description = "AWS Region"
  type        = string
  default     = "ap-northeast-2"
}

variable "project_name" {
  description = "프로젝트 이름 (파라미터 경로 prefix)"
  type        = string
  default     = "billage"
}
