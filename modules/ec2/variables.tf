# modules/ec2/variables.tf

variable "project_name" {
  description = "프로젝트 이름"
  type        = string
}

variable "env" {
  description = "환경 (dev, prod)"
  type        = string
}

variable "instance_name" {
  description = "인스턴스 이름 (예: main-server, monitoring-server)"
  type        = string
  default     = "main-server"
}

variable "instance_role" {
  description = "인스턴스 역할 (예: main-server, monitoring-target, monitoring-server)"
  type        = string
  default     = "main-server"
}

variable "instance_type" {
  description = "EC2 인스턴스 타입"
  type        = string
  default     = "t4g.medium"  # ARM 기반, 2 vCPU, 4GB RAM, 월 약 3.4만원
}

variable "subnet_id" {
  description = "서브넷 ID"
  type        = string
}

variable "security_group_ids" {
  description = "보안 그룹 ID 목록"
  type        = list(string)
}

variable "root_volume_size" {
  description = "루트 볼륨 크기 (GB)"
  type        = number
  default     = 20  # Ubuntu + Docker + MySQL 등 고려
}

variable "create_key_pair" {
  description = "새로운 키페어 생성 여부"
  type        = bool
  default     = false
}

variable "public_key" {
  description = "SSH 공개 키 (create_key_pair가 true일 때 필요)"
  type        = string
  default     = ""
}

variable "existing_key_name" {
  description = "기존 키페어 이름 (create_key_pair가 false일 때 필요)"
  type        = string
  default     = ""
}

variable "create_eip" {
  description = "Elastic IP 생성 여부"
  type        = bool
  default     = true  # 고정 IP 필요 시 true
}

variable "user_data" {
  description = "EC2 인스턴스 시작 시 실행할 스크립트"
  type        = string
  default     = ""
}

variable "additional_tags" {
  description = "추가 태그"
  type        = map(string)
  default     = {}
}

variable "iam_instance_profile" {
  description = "IAM Instance Profile 이름"
  type        = string
  default     = ""
}
