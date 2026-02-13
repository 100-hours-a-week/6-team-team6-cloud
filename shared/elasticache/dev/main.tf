# shared/elasticache/dev/main.tf
# Billage ElastiCache Redis (Dev 환경)

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
      Component   = "shared-elasticache"
    }
  }
}

#==============================================================================
# Data Sources
#==============================================================================
data "aws_vpc" "main" {
  tags = {
    Name = "${var.project_name}-${var.env}-vpc"
  }
}

# RDS에서 생성한 Private 서브넷 참조
data "aws_subnets" "private" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.main.id]
  }

  filter {
    name   = "tag:Name"
    values = ["${var.project_name}-${var.env}-rds-private-*"]
  }
}

#==============================================================================
# Security Group
#==============================================================================
resource "aws_security_group" "redis" {
  name        = "${var.project_name}-${var.env}-redis-sg"
  description = "Security group for ElastiCache Redis"
  vpc_id      = data.aws_vpc.main.id

  # Backend에서 접근 허용
  ingress {
    description = "Redis from VPC"
    from_port   = 6379
    to_port     = 6379
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.main.cidr_block]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-${var.env}-redis-sg"
  }
}

#==============================================================================
# ElastiCache Subnet Group
#==============================================================================
resource "aws_elasticache_subnet_group" "main" {
  name        = "${var.project_name}-${var.env}-redis-subnet"
  description = "Redis subnet group for ${var.env}"
  subnet_ids  = data.aws_subnets.private.ids

  tags = {
    Name = "${var.project_name}-${var.env}-redis-subnet"
  }
}

#==============================================================================
# ElastiCache Redis Cluster
#==============================================================================
resource "aws_elasticache_cluster" "main" {
  cluster_id           = "${var.project_name}-${var.env}-redis"
  engine               = "redis"
  engine_version       = "7.0"
  node_type            = var.node_type
  num_cache_nodes      = var.num_cache_nodes
  port                 = 6379
  parameter_group_name = "default.redis7"
  subnet_group_name    = aws_elasticache_subnet_group.main.name
  security_group_ids   = [aws_security_group.redis.id]

  maintenance_window = "Mon:20:00-Mon:21:00"

  tags = {
    Name = "${var.project_name}-${var.env}-redis"
  }
}