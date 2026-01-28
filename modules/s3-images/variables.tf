# modules/s3-images/variables.tf

variable "project_name" {
  description = "프로젝트 이름"
  type        = string
}

variable "env" {
  description = "환경 (dev, prod)"
  type        = string
}

variable "cors_allowed_origins" {
  description = "CORS 허용 오리진 목록 (프론트엔드 URL)"
  type        = list(string)
  default     = ["*"]
}

variable "enable_versioning" {
  description = "S3 버전 관리 활성화 여부"
  type        = bool
  default     = false
}