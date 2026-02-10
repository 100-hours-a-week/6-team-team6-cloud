# v2/envs/prod/main.tf
# Billage v2 Prod 환경 - Auto Scaling + ALB 아키텍처

terraform {
  required_version = ">= 1.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.env
      ManagedBy   = "terraform"
      Version     = "v2"
    }
  }
}

# TODO: Dev 환경 검증 후 구현
