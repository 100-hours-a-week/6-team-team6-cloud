# shared/vector-db/dev/main.tf
# Dev 전용 외부 Qdrant 서버

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
      Purpose     = "qdrant-dev-vector-db"
    }
  }
}

#==============================================================================
# Data Sources - 기존 Dev 네트워크 참조
#==============================================================================
data "aws_vpc" "dev" {
  tags = {
    Name = "${var.project_name}-${var.env}-vpc"
  }
}

data "aws_subnet" "public" {
  tags = {
    Name = "${var.project_name}-${var.env}-public-subnet"
  }
}

#==============================================================================
# Security Group - Qdrant
#==============================================================================
resource "aws_security_group" "qdrant" {
  name        = "${var.project_name}-${var.env}-qdrant-sg"
  description = "Security group for Qdrant dev server"
  vpc_id      = data.aws_vpc.dev.id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.ssh_allowed_cidr
  }

  ingress {
    description = "Qdrant HTTP"
    from_port   = 6333
    to_port     = 6333
    protocol    = "tcp"
    cidr_blocks = var.qdrant_allowed_cidr
  }

  dynamic "ingress" {
    for_each = length(var.qdrant_allowed_security_group_ids) > 0 ? [1] : []
    content {
      description     = "Qdrant HTTP from AI ASG SG"
      from_port       = 6333
      to_port         = 6333
      protocol        = "tcp"
      security_groups = var.qdrant_allowed_security_group_ids
    }
  }

  ingress {
    description = "Qdrant gRPC"
    from_port   = 6334
    to_port     = 6334
    protocol    = "tcp"
    cidr_blocks = var.qdrant_allowed_cidr
  }

  dynamic "ingress" {
    for_each = length(var.qdrant_allowed_security_group_ids) > 0 ? [1] : []
    content {
      description     = "Qdrant gRPC from AI ASG SG"
      from_port       = 6334
      to_port         = 6334
      protocol        = "tcp"
      security_groups = var.qdrant_allowed_security_group_ids
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-${var.env}-qdrant-sg"
  }
}

#==============================================================================
# EC2 Instance - Qdrant
#==============================================================================
resource "aws_instance" "qdrant" {
  ami                         = var.golden_ami_id
  instance_type               = var.instance_type
  subnet_id                   = data.aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.qdrant.id]
  key_name                    = var.key_name
  associate_public_ip_address = var.associate_public_ip

  user_data = templatefile("${path.module}/user_data_qdrant.sh.tpl", {
    qdrant_container_image = var.qdrant_container_image
    qdrant_api_key         = var.qdrant_api_key
  })

  root_block_device {
    volume_size           = var.root_volume_size
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  tags = {
    Name = "${var.project_name}-${var.env}-qdrant-server"
    Role = "qdrant"
  }
}

resource "aws_eip" "qdrant" {
  count    = var.create_eip ? 1 : 0
  instance = aws_instance.qdrant.id
  domain   = "vpc"

  tags = {
    Name = "${var.project_name}-${var.env}-qdrant-eip"
  }

  depends_on = [aws_instance.qdrant]
}

locals {
  qdrant_private_ip = aws_instance.qdrant.private_ip
  qdrant_public_ip  = var.create_eip ? aws_eip.qdrant[0].public_ip : aws_instance.qdrant.public_ip
}
