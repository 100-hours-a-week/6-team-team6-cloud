# shared/ecr/variables.tf

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

variable "services" {
  description = "ECR Repository를 생성할 서비스 목록"
  type        = list(string)
  default     = ["be", "fe", "ai"]
}
