# staging/test-server/main.tf
# DB 마이그레이션 리허설용 EC2
#
# 사용 후 terraform destroy로 정리

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
      Environment = "staging"
      ManagedBy   = "terraform"
      Purpose     = "db-migration-rehearsal"
    }
  }
}

#==============================================================================
# Data Sources - 기존 VPC/Subnet 참조
#==============================================================================
data "aws_vpc" "dev" {
  tags = {
    Name = "${var.project_name}-dev-vpc"
  }
}

data "aws_subnet" "public" {
  tags = {
    Name = "${var.project_name}-dev-public-subnet"
  }
}

#==============================================================================
# Security Group - 리허설 전용
#==============================================================================
resource "aws_security_group" "rehearsal" {
  name        = "${var.project_name}-rehearsal-sg"
  description = "Security group for DB migration rehearsal"
  vpc_id      = data.aws_vpc.dev.id

  # SSH
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.ssh_allowed_cidr
  }

  # HTTP
  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # HTTPS
  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # WAS - Host DB (8080)
  ingress {
    description = "WAS Host DB"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # WAS - RDS (8081)
  ingress {
    description = "WAS RDS"
    from_port   = 8081
    to_port     = 8081
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # MySQL (내부용)
  ingress {
    description = "MySQL"
    from_port   = 3306
    to_port     = 3306
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.dev.cidr_block]
  }

  # Next.js (3000)
  ingress {
    description = "Next.js"
    from_port   = 3000
    to_port     = 3000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # FastAPI (5000)
  ingress {
    description = "FastAPI"
    from_port   = 5000
    to_port     = 5000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-rehearsal-sg"
  }
}

#==============================================================================
# EC2 Instance - 리허설 서버
#==============================================================================
resource "aws_instance" "rehearsal" {
  ami                    = var.ami_id
  instance_type          = var.instance_type
  subnet_id              = data.aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.rehearsal.id]
  key_name               = var.key_name

  root_block_device {
    volume_size = var.root_volume_size
    volume_type = "gp3"
    encrypted   = true
  }

  tags = {
    Name = "${var.project_name}-rehearsal-ec2"
  }
}

#==============================================================================
# Elastic IP
#==============================================================================
resource "aws_eip" "rehearsal" {
  instance = aws_instance.rehearsal.id
  domain   = "vpc"

  tags = {
    Name = "${var.project_name}-rehearsal-eip"
  }
}
