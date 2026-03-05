# shared/rds/prod/main.tf
# Billage RDS MySQL (v2 Prod 환경 전용)

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
      Component   = "shared-rds"
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

data "aws_availability_zones" "available" {
  state = "available"
}

#==============================================================================
# Private Subnets for RDS (자체 생성)
#==============================================================================
resource "aws_subnet" "private_a" {
  vpc_id                  = data.aws_vpc.main.id
  cidr_block              = var.private_subnet_cidr_a
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = false

  tags = {
    Name = "${var.project_name}-${var.env}-v2-rds-private-a"
    Type = "private"
  }
}

resource "aws_subnet" "private_c" {
  vpc_id                  = data.aws_vpc.main.id
  cidr_block              = var.private_subnet_cidr_c
  availability_zone       = data.aws_availability_zones.available.names[2]
  map_public_ip_on_launch = false

  tags = {
    Name = "${var.project_name}-${var.env}-v2-rds-private-c"
    Type = "private"
  }
}

# Private Route Table (인터넷 접근 없음)
resource "aws_route_table" "private" {
  vpc_id = data.aws_vpc.main.id

  tags = {
    Name = "${var.project_name}-${var.env}-v2-rds-private-rt"
  }
}

resource "aws_route" "private_to_management" {
  route_table_id            = aws_route_table.private.id
  destination_cidr_block    = var.management_vpc_cidr
  vpc_peering_connection_id = var.management_vpc_peering_connection_id
}

resource "aws_route_table_association" "private_a" {
  subnet_id      = aws_subnet.private_a.id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "private_c" {
  subnet_id      = aws_subnet.private_c.id
  route_table_id = aws_route_table.private.id
}

#==============================================================================
# Security Group
#==============================================================================
resource "aws_security_group" "rds" {
  name        = "${var.project_name}-${var.env}-v2-rds-sg"
  description = "Security group for v2 RDS MySQL"
  vpc_id      = data.aws_vpc.main.id

  # Backend에서 접근 허용 (VPC 전체 CIDR)
  ingress {
    description = "MySQL from VPC"
    from_port   = 3306
    to_port     = 3306
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.main.cidr_block, var.management_vpc_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-${var.env}-v2-rds-sg"
  }
}

#==============================================================================
# DB Subnet Group
#==============================================================================
resource "aws_db_subnet_group" "main" {
  name        = "${var.project_name}-${var.env}-v2-db-subnet-group"
  description = "DB subnet group for v2 ${var.env}"
  subnet_ids  = [aws_subnet.private_a.id, aws_subnet.private_c.id]

  tags = {
    Name = "${var.project_name}-${var.env}-v2-db-subnet-group"
  }
}

#==============================================================================
# DB Parameter Group
#==============================================================================
resource "aws_db_parameter_group" "main" {
  name   = "${var.project_name}-${var.env}-v2-mysql-params"
  family = "mysql8.0"

  parameter {
    name  = "character_set_server"
    value = "utf8mb4"
  }

  parameter {
    name  = "character_set_client"
    value = "utf8mb4"
  }

  parameter {
    name  = "collation_server"
    value = "utf8mb4_unicode_ci"
  }

  parameter {
    name  = "time_zone"
    value = "Asia/Seoul"
  }

  parameter {
    name  = "slow_query_log"
    value = "1"
  }

  parameter {
    name  = "long_query_time"
    value = "2"
  }

  tags = {
    Name = "${var.project_name}-${var.env}-v2-mysql-params"
  }
}

#==============================================================================
# RDS Instance
#==============================================================================
resource "aws_db_instance" "main" {
  identifier = "${var.project_name}-${var.env}-v2-mysql"

  engine               = "mysql"
  engine_version       = "8.0"
  instance_class       = var.instance_class
  parameter_group_name = aws_db_parameter_group.main.name

  allocated_storage     = var.allocated_storage
  max_allocated_storage = var.max_allocated_storage
  storage_type          = "gp3"
  storage_encrypted     = true

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = false
  multi_az               = var.multi_az

  db_name  = var.db_name
  username = var.username
  password = var.password

  backup_retention_period = 7
  backup_window           = "18:00-19:00" # KST 03:00-04:00
  maintenance_window      = "Mon:19:00-Mon:20:00"

  deletion_protection = var.deletion_protection
  skip_final_snapshot = var.skip_final_snapshot

  tags = {
    Name = "${var.project_name}-${var.env}-v2-mysql"
  }
}
