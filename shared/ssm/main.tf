# shared/ssm/main.tf
# SSM Parameter Store 환경변수 및 시크릿 관리
#
# 사용법:
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
      Project   = var.project_name
      ManagedBy = "terraform"
      Purpose   = "ssm-parameters"
    }
  }
}

#==============================================================================
# Local Variables
#==============================================================================
locals {
  environments = ["dev", "prod"]

  # 일반 설정값 (String) - 환경별
  config_parameters = {
    dev = {
      # Backend
      "be/spring-profile"    = "dev"
      "be/cors-allowed"      = "*"
      "be/access-duration"   = "7200000"
      "be/refresh-duration"  = "604800000"
      "be/ai-base-url"       = "https://dev.billages.com/"
      "be/ai-timeout"        = "10"

      # Frontend
      "fe/api-url"           = "https://api.dev.billages.com"
      "fe/nextauth-url"      = "https://dev.billages.com"
      "fe/auth-trust-host"   = "true"
      "fe/image-hostname"    = "billage-images-dev.s3.ap-northeast-2.amazonaws.com"

      # S3
      "s3/bucket-name"       = "billage-images-dev"
      "s3/region"            = "ap-northeast-2"
    }

    prod = {
      # Backend
      "be/spring-profile"    = "prod"
      "be/cors-allowed"      = "https://www.billages.com,https://billages.com"
      "be/access-duration"   = "7200000"
      "be/refresh-duration"  = "604800000"
      "be/ai-base-url"       = "https://billages.com/"
      "be/ai-timeout"        = "10"

      # Frontend
      "fe/api-url"           = "https://api.billages.com"
      "fe/nextauth-url"      = "https://www.billages.com"
      "fe/auth-trust-host"   = "true"
      "fe/image-hostname"    = "billage-images-prod.s3.ap-northeast-2.amazonaws.com"

      # S3
      "s3/bucket-name"       = "billage-images-prod"
      "s3/region"            = "ap-northeast-2"
    }
  }

  # 시크릿 (SecureString) - Console에서 설정
  secret_parameters = {
    dev = [
      "be/db-url",
      "be/db-username",
      "be/db-password",
      "be/jwt-secret",
      "fe/nextauth-secret",
      "s3/access-key",
      "s3/secret-key"
    ]

    prod = [
      "be/db-url",
      "be/db-username",
      "be/db-password",
      "be/jwt-secret",
      "fe/nextauth-secret",
      "s3/access-key",
      "s3/secret-key"
    ]
  }
}

#==============================================================================
# String Parameters (일반 설정값)
#==============================================================================
resource "aws_ssm_parameter" "config" {
  for_each = merge([
    for env in local.environments : {
      for key, value in local.config_parameters[env] :
      "${env}/${key}" => {
        env   = env
        key   = key
        value = value
      }
    }
  ]...)

  name        = "/${var.project_name}/${each.key}"
  description = "Config: ${each.value.key} for ${each.value.env}"
  type        = "String"
  value       = each.value.value

  tags = {
    Name        = each.key
    Environment = each.value.env
    Type        = "config"
  }
}

#==============================================================================
# SecureString Parameters (시크릿)
# 값은 AWS Console에서 설정
#==============================================================================
resource "aws_ssm_parameter" "secrets" {
  for_each = toset(flatten([
    for env in local.environments : [
      for secret in local.secret_parameters[env] :
      "${env}/${secret}"
    ]
  ]))

  name        = "/${var.project_name}/${each.key}"
  description = "Secret: ${each.key}"
  type        = "SecureString"
  value       = "PLACEHOLDER"

  lifecycle {
    ignore_changes = [value]
  }

  tags = {
    Name        = each.key
    Environment = split("/", each.key)[0]
    Type        = "secret"
  }
}


