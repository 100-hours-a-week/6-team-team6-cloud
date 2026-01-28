# envs/s3-images/backend.tf
# S3 이미지 저장소 인프라 - Terraform 설정

terraform {
  required_version = ">= 1.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # 기존 dev 인프라와 별도의 state 파일 사용
  backend "s3" {
    bucket         = "billage-terraform-state-dev"
    key            = "s3-images/terraform.tfstate"
    region         = "ap-northeast-2"
    dynamodb_table = "billage-terraform-lock-dev"
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