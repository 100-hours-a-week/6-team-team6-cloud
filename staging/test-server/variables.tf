# staging/test-server/variables.tf

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

variable "ami_id" {
  description = "리허설용 AMI ID (Prod 스냅샷)"
  type        = string
  # billage-single-instance-staging-ami
}

variable "instance_type" {
  description = "EC2 인스턴스 타입"
  type        = string
  default     = "t4g.medium"
}

variable "key_name" {
  description = "SSH 키페어 이름"
  type        = string
}

variable "root_volume_size" {
  description = "루트 볼륨 크기 (GB)"
  type        = number
  default     = 30
}

variable "ssh_allowed_cidr" {
  description = "SSH 접근 허용 CIDR"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}