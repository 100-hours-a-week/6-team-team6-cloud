# shared/vector-db/prod/variables.tf

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

variable "golden_ami_id" {
  description = "v2/packer로 빌드한 Golden AMI ID"
  type        = string
}

variable "instance_type" {
  description = "Qdrant EC2 인스턴스 타입 (4GB RAM 권장)"
  type        = string
  default     = "t3.medium"
}

variable "key_name" {
  description = "기존 EC2 키페어 이름"
  type        = string
  default     = "billage-keypair"
}

variable "root_volume_size" {
  description = "루트 볼륨 크기 (GB)"
  type        = number
  default     = 20
}

variable "create_eip" {
  description = "Elastic IP 생성 여부"
  type        = bool
  default     = false
}

variable "associate_public_ip" {
  description = "퍼블릭 IP 자동 할당 여부 (NAT 미구성 시 Docker Hub pull을 위해 필요)"
  type        = bool
  default     = true
}

variable "ssh_allowed_cidr" {
  description = "SSH 접근 허용 CIDR"
  type        = list(string)
  default     = ["10.2.0.0/16"]
}

variable "qdrant_allowed_cidr" {
  description = "Qdrant(6333, 6334) 접근 허용 CIDR"
  type        = list(string)
  default     = ["10.1.0.0/16"]
}

variable "qdrant_container_image" {
  description = "Qdrant Docker 이미지"
  type        = string
  default     = "qdrant/qdrant:latest"
}

variable "qdrant_api_key" {
  description = "Qdrant API Key (QDRANT__SERVICE__API_KEY)"
  type        = string
  sensitive   = true
}
