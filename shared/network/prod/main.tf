# shared/network/prod/main.tf
# Prod 환경 VPC (모든 인프라의 기반)
#
# 이 모듈은 절대 destroy하면 안됨!
# v1, v2, RDS, RabbitMQ 모두 이 VPC에 의존
#
# [마이그레이션 참고]
# 기존 Prod VPC는 v1-bigbang/envs/prod에서 modules/vpc로 생성되어 있음.
# v2 전환 시 아래 순서로 VPC 소유권을 이관해야 함:
#
# Step 1: 기존 리소스 ID 확인
#   cd v1-bigbang/envs/prod
#   terraform state show module.vpc.aws_vpc.main           → vpc-xxxxx
#   terraform state show module.vpc.aws_internet_gateway.main → igw-xxxxx
#   terraform state show module.vpc.aws_subnet.public       → subnet-xxxxx
#   terraform state show module.vpc.aws_route_table.public  → rtb-xxxxx
#
# Step 2: shared/network/prod에 import
#   cd shared/network/prod
#   terraform init
#   terraform import aws_vpc.main <vpc-id>
#   terraform import aws_internet_gateway.main <igw-id>
#   terraform import aws_subnet.public_a <subnet-id>
#   terraform import aws_route_table.public <rtb-id>
#   terraform import aws_route.public_internet <rtb-id>_0.0.0.0/0
#   terraform import aws_route_table_association.public_a <subnet-id>/<rtb-id>
#
# Step 3: plan으로 변경사항 없는지 확인
#   terraform plan
#   (태그 차이만 있을 수 있음 - Environment/Project 태그 형식 약간 다름)
#
# Step 4: v1-bigbang/envs/prod에서 VPC를 state에서만 제거 (실제 리소스는 유지)
#   cd v1-bigbang/envs/prod
#   terraform state rm module.vpc.aws_vpc.main
#   terraform state rm module.vpc.aws_internet_gateway.main
#   terraform state rm module.vpc.aws_subnet.public
#   terraform state rm module.vpc.aws_route_table.public
#   terraform state rm module.vpc.aws_route.public_internet
#   terraform state rm module.vpc.aws_route_table_association.public
#
# 완료 후 v1 destroy해도 VPC는 shared/network/prod가 관리하므로 안전함

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
      Component   = "shared-network"
    }
  }
}

#==============================================================================
# VPC
#==============================================================================
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "${var.project_name}-${var.env}-vpc"
  }
}

#==============================================================================
# Internet Gateway
#==============================================================================
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.project_name}-${var.env}-igw"
  }
}

#==============================================================================
# Public Subnet (AZ-a) - v1, v2 공용
#==============================================================================
resource "aws_subnet" "public_a" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidr_a
  availability_zone       = "${var.aws_region}a"
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.project_name}-${var.env}-public-subnet"
    Type = "public"
  }
}

#==============================================================================
# Public Route Table
#==============================================================================
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.project_name}-${var.env}-public-rt"
  }
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.main.id
}

resource "aws_route_table_association" "public_a" {
  subnet_id      = aws_subnet.public_a.id
  route_table_id = aws_route_table.public.id
}
