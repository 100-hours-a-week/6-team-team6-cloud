# shared/rabbitmq/prod/main.tf
# WebSocket Pub/Sub용 RabbitMQ (Single Instance)

terraform {
  required_version = ">= 1.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
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
      Component   = "shared-rabbitmq"
    }
  }
}

data "terraform_remote_state" "v1" {
  backend = "s3"
  config = {
    bucket         = var.v1_state_bucket
    key            = var.v1_state_key
    region         = var.aws_region
    dynamodb_table = var.v1_state_lock_table
  }
}

data "terraform_remote_state" "v2" {
  backend = "s3"
  config = {
    bucket         = var.v2_state_bucket
    key            = var.v2_state_key
    region         = var.aws_region
    dynamodb_table = var.v2_state_lock_table
  }
}

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
  v1_main_sg_id      = data.terraform_remote_state.v1.outputs.main_security_group_id
  v2_backend_sg_id   = data.terraform_remote_state.v2.outputs.security_group_ids.backend
  rabbitmq_subnet_id = data.terraform_remote_state.v2.outputs.private_subnet_ids[0]
}

resource "random_password" "rabbitmq" {
  length  = 32
  special = false
}

resource "aws_iam_role" "rabbitmq" {
  name = "${var.project_name}-${var.env}-rabbitmq-role"

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
  role       = aws_iam_role.rabbitmq.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "cloudwatch_agent" {
  role       = aws_iam_role.rabbitmq.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_iam_instance_profile" "rabbitmq" {
  name = "${var.project_name}-${var.env}-rabbitmq-profile"
  role = aws_iam_role.rabbitmq.name
}

resource "aws_security_group" "rabbitmq" {
  name        = "${var.project_name}-${var.env}-rabbitmq-sg"
  description = "Security group for RabbitMQ broker"
  vpc_id      = data.aws_vpc.main.id

  ingress {
    description     = "AMQP from v1/v2 backend security groups"
    from_port       = 5672
    to_port         = 5672
    protocol        = "tcp"
    security_groups = [local.v1_main_sg_id, local.v2_backend_sg_id]
  }

  ingress {
    description     = "STOMP from v1/v2 backend security groups"
    from_port       = 61613
    to_port         = 61613
    protocol        = "tcp"
    security_groups = [local.v1_main_sg_id, local.v2_backend_sg_id]
  }

  ingress {
    description = "RabbitMQ Management UI"
    from_port   = 15672
    to_port     = 15672
    protocol    = "tcp"
    cidr_blocks = var.management_access_cidrs
  }

  ingress {
    description = "SSH for operations"
    from_port   = 22
    to_port     = 22
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
    Name = "${var.project_name}-${var.env}-rabbitmq-sg"
  }
}

resource "aws_instance" "rabbitmq" {
  ami                         = data.aws_ami.amazon_linux.id
  instance_type               = var.instance_type
  subnet_id                   = local.rabbitmq_subnet_id
  vpc_security_group_ids      = [aws_security_group.rabbitmq.id]
  iam_instance_profile        = aws_iam_instance_profile.rabbitmq.name
  key_name                    = var.key_name
  associate_public_ip_address = false

  user_data = templatefile("${path.module}/user_data_rabbitmq.sh.tpl", {
    rabbitmq_username = var.rabbitmq_username
    rabbitmq_password = random_password.rabbitmq.result
  })

  root_block_device {
    volume_size           = var.root_volume_size
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  tags = {
    Name = "${var.project_name}-${var.env}-rabbitmq"
    Role = "rabbitmq"
  }
}

resource "aws_ssm_parameter" "rabbitmq_be_config" {
  for_each = {
    "rabbitmq-enabled"    = "true"
    "rabbitmq-stomp-host" = aws_instance.rabbitmq.private_ip
    "rabbitmq-stomp-port" = "61613"
    "rabbitmq-amqp-host"  = aws_instance.rabbitmq.private_ip
    "rabbitmq-amqp-port"  = "5672"
    "rabbitmq-username"   = var.rabbitmq_username
  }

  name      = "/${var.project_name}/${var.env}/be/${each.key}"
  type      = "String"
  value     = each.value
  overwrite = true
}

resource "aws_ssm_parameter" "rabbitmq_be_password" {
  name      = "/${var.project_name}/${var.env}/be/rabbitmq-password"
  type      = "SecureString"
  value     = random_password.rabbitmq.result
  overwrite = true
}
