# envs/s3-images-prod/backend.tf
# S3 이미지 저장소 인프라 (Production) - Terraform 설정

terraform {
  required_version = ">= 1.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # prod 인프라와 동일한 state 버킷, 별도 key
  backend "s3" {
    bucket         = "billage-terraform-state-prod"
    key            = "s3-images/terraform.tfstate"
    region         = "ap-northeast-2"
    dynamodb_table = "billage-terraform-lock-prod"
    encrypt        = true
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.env
      ManagedBy   = "Terraform"
    }
  }
}