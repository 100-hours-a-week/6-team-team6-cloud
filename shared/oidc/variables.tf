# shared/oidc/variables.tf

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

variable "allowed_repo_branches" {
  description = "OIDC 인증을 허용할 GitHub Repository 및 브랜치 목록"
  type        = map(list(string))
  default = {
    # Backend: main, dev 브랜치만 허용
    "100-hours-a-week/6-team-team6-be" = ["main", "dev"]
    # Frontend: develop, main 브랜치만 허용
    "100-hours-a-week/6-team-team6-fe" = ["develop", "main"]
    # AI: develop, main 브랜치만 허용
    "100-hours-a-week/6-team-team6-ai" = ["develop", "main"]
  }
}