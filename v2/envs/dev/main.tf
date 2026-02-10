# v2/envs/dev/main.tf
# Billage v2 Dev 환경 - Auto Scaling + ALB 아키텍처
#
# Phase 2: Scalable Architecture
# - ALB + Target Groups
# - Auto Scaling Groups (Backend, Frontend, AI)
# - RDS MySQL + ElastiCache Redis
# - ECR에서 Docker 이미지 Pull

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

#==============================================================================
# TODO: VPC 모듈 (Multi-AZ)
#==============================================================================
# module "vpc" {
#   source = "../../../modules/vpc"
# }

#==============================================================================
# TODO: RDS 모듈
#==============================================================================
# module "rds" {
#   source = "../../../modules/rds"
# }

#==============================================================================
# TODO: ElastiCache 모듈
#==============================================================================
# module "elasticache" {
#   source = "../../../modules/elasticache"
# }

#==============================================================================
# TODO: ALB 모듈
#==============================================================================
# module "alb" {
#   source = "../../../modules/alb"
# }

#==============================================================================
# TODO: ASG 모듈 (Backend, Frontend, AI)
#==============================================================================
# module "asg_backend" {
#   source = "../../../modules/asg"
# }