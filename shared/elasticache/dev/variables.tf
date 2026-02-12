# shared/elasticache/dev/variables.tf

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

#==============================================================================
# ElastiCache 설정
#==============================================================================
variable "node_type" {
  description = "Redis 노드 타입"
  type        = string
  default     = "cache.t4g.micro"
}

variable "num_cache_nodes" {
  description = "캐시 노드 수"
  type        = number
  default     = 1
}