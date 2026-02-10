# envs/s3-images-prod/variables.tf

#==============================================================================
# 공통 설정
#==============================================================================
variable "project_name" {
  description = "프로젝트 이름"
  type        = string
  default     = "billage"
}

variable "env" {
  description = "환경 (dev, prod)"
  type        = string
  default     = "prod"
}

variable "aws_region" {
  description = "AWS 리전"
  type        = string
  default     = "ap-northeast-2"
}

#==============================================================================
# S3 설정
#==============================================================================
variable "cors_allowed_origins" {
  description = "CORS 허용 오리진 목록 (프론트엔드 URL)"
  type        = list(string)
  default     = ["*"]
}

variable "enable_versioning" {
  description = "S3 버전 관리 활성화 여부 (이미지 실수 삭제 방지)"
  type        = bool
  default     = true
}