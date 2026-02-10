variable "aws_region" {
  type        = string
  default     = "ap-northeast-2"
  description = "AWS region to build the AMI"
}

variable "instance_type" {
  type        = string
  default     = "t3.medium"
  description = "EC2 instance type for building the AMI"
}

variable "ami_name_prefix" {
  type        = string
  default     = "billage-golden-ami"
  description = "Prefix for the AMI name"
}

variable "source_ami_filter_name" {
  type        = string
  default     = "ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"
  description = "Filter pattern for source AMI"
}

variable "source_ami_owner" {
  type        = string
  default     = "099720109477" # Canonical
  description = "Owner ID of the source AMI"
}

variable "ssh_username" {
  type        = string
  default     = "ubuntu"
  description = "SSH username for the builder"
}

variable "vpc_id" {
  type        = string
  default     = ""
  description = "VPC ID to launch the builder instance (optional)"
}

variable "subnet_id" {
  type        = string
  default     = ""
  description = "Subnet ID to launch the builder instance (optional)"
}

variable "tags" {
  type = map(string)
  default = {
    Project     = "billage"
    Environment = "common"
    ManagedBy   = "packer"
  }
  description = "Tags to apply to the AMI and snapshots"
}

variable "loki_url" {
  type        = string
  default     = "http://loki:3100/loki/api/v1/push"
  description = "Loki push API endpoint URL for Promtail"
}