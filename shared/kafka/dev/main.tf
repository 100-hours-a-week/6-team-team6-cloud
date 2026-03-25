# shared/kafka/dev/main.tf
# Kafka (Docker) - Dev 환경

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
      Component   = "shared-kafka"
    }
  }
}

#==============================================================================
# Remote State
#==============================================================================
data "terraform_remote_state" "v2" {
  backend = "s3"
  config = {
    bucket         = var.v2_state_bucket
    key            = var.v2_state_key
    region         = var.aws_region
    dynamodb_table = var.v2_state_lock_table
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

data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

locals {
  v2_backend_sg_id = data.terraform_remote_state.v2.outputs.security_group_ids.backend
  kafka_subnet_id  = data.terraform_remote_state.v2.outputs.private_subnet_ids[0]
}

#==============================================================================
# IAM
#==============================================================================
resource "aws_iam_role" "kafka" {
  name = "${var.project_name}-${var.env}-kafka-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.kafka.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "cloudwatch_agent" {
  role       = aws_iam_role.kafka.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_iam_instance_profile" "kafka" {
  name = "${var.project_name}-${var.env}-kafka-profile"
  role = aws_iam_role.kafka.name
}

#==============================================================================
# Security Group
#==============================================================================
resource "aws_security_group" "kafka" {
  name        = "${var.project_name}-${var.env}-kafka-sg"
  description = "Security group for Kafka broker"
  vpc_id      = data.aws_vpc.main.id

  ingress {
    description     = "Kafka from v2 backend"
    from_port       = 9092
    to_port         = 9092
    protocol        = "tcp"
    security_groups = [local.v2_backend_sg_id]
  }

  ingress {
    description = "Kafka (management CIDR)"
    from_port   = 9092
    to_port     = 9092
    protocol    = "tcp"
    cidr_blocks = var.management_access_cidrs
  }

  ingress {
    description = "Kafka UI (management CIDR)"
    from_port   = 8989
    to_port     = 8989
    protocol    = "tcp"
    cidr_blocks = var.management_access_cidrs
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-${var.env}-kafka-sg"
  }
}

#==============================================================================
# EC2 Instance (Kafka via Docker)
#==============================================================================
resource "aws_instance" "kafka" {
  ami                         = data.aws_ami.amazon_linux.id
  instance_type               = var.instance_type
  subnet_id                   = local.kafka_subnet_id
  vpc_security_group_ids      = [aws_security_group.kafka.id]
  iam_instance_profile        = aws_iam_instance_profile.kafka.name
  key_name                    = var.key_name
  associate_public_ip_address = false

  user_data = templatefile("${path.module}/user_data_kafka.sh.tpl", {
    private_ip = ""  # EC2 부팅 시 자기 IP로 자동 설정됨
  })

  root_block_device {
    volume_size           = var.root_volume_size
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  tags = {
    Name = "${var.project_name}-${var.env}-kafka"
    Role = "kafka"
  }
}

#==============================================================================
# SSM Parameters
#==============================================================================
resource "aws_ssm_parameter" "kafka_bootstrap_servers" {
  name      = "/${var.project_name}/${var.env}/be/kafka-bootstrap-servers"
  type      = "String"
  value     = "${aws_instance.kafka.private_ip}:9092"
  overwrite = true

  tags = {
    Name        = "kafka-bootstrap-servers"
    Environment = var.env
    Type        = "config"
  }
}