variable "project_name" {
  type = string
}

variable "env" {
  type = string
}

variable "cluster_name" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "vpc_cidr" {
  type = string
}

variable "management_cidrs" {
  type = list(string)
}

variable "enable_ssh" {
  type = bool
}

variable "ssh_allowed_cidrs" {
  type = list(string)
}

variable "tags" {
  type = map(string)
}

locals {
  effective_ssh_cidrs = distinct(concat(var.management_cidrs, var.ssh_allowed_cidrs))
}

resource "aws_security_group" "cluster_mesh" {
  name        = "${var.cluster_name}-cluster-mesh-sg"
  description = "Shared east-west traffic for kubeadm nodes"
  vpc_id      = var.vpc_id

  ingress {
    description = "All traffic between cluster nodes"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    self        = true
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(
    var.tags,
    {
      Name = "${var.cluster_name}-cluster-mesh-sg"
    }
  )
}

resource "aws_security_group" "control_plane" {
  name        = "${var.cluster_name}-control-plane-sg"
  description = "Access rules for kubeadm control-plane nodes"
  vpc_id      = var.vpc_id

  ingress {
    description = "Kube-apiserver from cluster VPC"
    from_port   = 6443
    to_port     = 6443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  dynamic "ingress" {
    for_each = var.management_cidrs

    content {
      description = "Kube-apiserver from management network"
      from_port   = 6443
      to_port     = 6443
      protocol    = "tcp"
      cidr_blocks = [ingress.value]
    }
  }

  ingress {
    description = "etcd peer and client traffic between control-plane nodes"
    from_port   = 2379
    to_port     = 2380
    protocol    = "tcp"
    self        = true
  }

  dynamic "ingress" {
    for_each = var.enable_ssh ? local.effective_ssh_cidrs : []

    content {
      description = "SSH to control-plane nodes"
      from_port   = 22
      to_port     = 22
      protocol    = "tcp"
      cidr_blocks = [ingress.value]
    }
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(
    var.tags,
    {
      Name = "${var.cluster_name}-control-plane-sg"
    }
  )
}

resource "aws_security_group" "app" {
  name        = "${var.cluster_name}-app-sg"
  description = "Role-specific access rules for app worker nodes"
  vpc_id      = var.vpc_id

  ingress {
    description = "NodePort ingress from the cluster VPC for ALB to ingress-nginx"
    from_port   = 30000
    to_port     = 32767
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  dynamic "ingress" {
    for_each = var.enable_ssh ? local.effective_ssh_cidrs : []

    content {
      description = "SSH to app nodes"
      from_port   = 22
      to_port     = 22
      protocol    = "tcp"
      cidr_blocks = [ingress.value]
    }
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(
    var.tags,
    {
      Name = "${var.cluster_name}-app-sg"
    }
  )
}

resource "aws_security_group" "data" {
  name        = "${var.cluster_name}-data-sg"
  description = "Role-specific access rules for data worker nodes"
  vpc_id      = var.vpc_id

  dynamic "ingress" {
    for_each = var.enable_ssh ? local.effective_ssh_cidrs : []

    content {
      description = "SSH to data nodes"
      from_port   = 22
      to_port     = 22
      protocol    = "tcp"
      cidr_blocks = [ingress.value]
    }
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(
    var.tags,
    {
      Name = "${var.cluster_name}-data-sg"
    }
  )
}

output "cluster_mesh_security_group_id" {
  value = aws_security_group.cluster_mesh.id
}

output "control_plane_security_group_id" {
  value = aws_security_group.control_plane.id
}

output "app_security_group_id" {
  value = aws_security_group.app.id
}

output "data_security_group_id" {
  value = aws_security_group.data.id
}
