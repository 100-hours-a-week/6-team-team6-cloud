variable "project_name" {
  type = string
}

variable "env" {
  type = string
}

variable "cluster_name" {
  type = string
}

variable "vpc_cidr" {
  type = string
}

variable "availability_zones" {
  type = list(string)
}

variable "tags" {
  type = map(string)
}

locals {
  az_count = length(var.availability_zones)

  public_subnet_cidrs = {
    for idx, az in var.availability_zones : az => cidrsubnet(var.vpc_cidr, 8, idx)
  }

  control_plane_subnet_cidrs = {
    for idx, az in var.availability_zones : az => cidrsubnet(var.vpc_cidr, 8, idx + local.az_count)
  }

  worker_subnet_cidrs = {
    for idx, az in var.availability_zones : az => cidrsubnet(var.vpc_cidr, 8, idx + (local.az_count * 2))
  }
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = merge(
    var.tags,
    {
      Name = "${var.cluster_name}-vpc"
    }
  )
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = merge(
    var.tags,
    {
      Name = "${var.cluster_name}-igw"
    }
  )
}

resource "aws_subnet" "public" {
  for_each = local.public_subnet_cidrs

  vpc_id                  = aws_vpc.this.id
  cidr_block              = each.value
  availability_zone       = each.key
  map_public_ip_on_launch = true

  tags = merge(
    var.tags,
    {
      Name                                        = "${var.cluster_name}-public-${each.key}"
      Tier                                        = "public"
      "kubernetes.io/role/elb"                    = "1"
      "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    }
  )
}

resource "aws_subnet" "control_plane" {
  for_each = local.control_plane_subnet_cidrs

  vpc_id                  = aws_vpc.this.id
  cidr_block              = each.value
  availability_zone       = each.key
  map_public_ip_on_launch = false

  tags = merge(
    var.tags,
    {
      Name                                        = "${var.cluster_name}-control-plane-${each.key}"
      Tier                                        = "private-control-plane"
      "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    }
  )
}

resource "aws_subnet" "worker" {
  for_each = local.worker_subnet_cidrs

  vpc_id                  = aws_vpc.this.id
  cidr_block              = each.value
  availability_zone       = each.key
  map_public_ip_on_launch = false

  tags = merge(
    var.tags,
    {
      Name                                        = "${var.cluster_name}-worker-${each.key}"
      Tier                                        = "private-worker"
      "kubernetes.io/role/internal-elb"           = "1"
      "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    }
  )
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  tags = merge(
    var.tags,
    {
      Name = "${var.cluster_name}-public-rt"
    }
  )
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  for_each = aws_subnet.public

  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  for_each = toset(var.availability_zones)

  vpc_id = aws_vpc.this.id

  tags = merge(
    var.tags,
    {
      Name = "${var.cluster_name}-private-rt-${each.key}"
    }
  )
}

# -----------------------------------------------------------------------------
# NAT Instance (replaces NAT Gateway for cost optimization + chaos engineering)
# - t3.nano: ~$3.80/month (vs NAT Gateway ~$32/month)
# - FIS aws:ec2:stop-instances 대상 (Role=nat 태그로 타겟팅)
# - SPOF — 카오스 실험으로 영향 범위 검증 후 ASG 자동 복구 적용 예정
# -----------------------------------------------------------------------------

data "aws_ami" "nat" {
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

resource "aws_security_group" "nat" {
  name_prefix = "${var.cluster_name}-nat-"
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "All traffic from private subnets (control-plane + worker)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = concat(
      values(local.control_plane_subnet_cidrs),
      values(local.worker_subnet_cidrs)
    )
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(
    var.tags,
    {
      Name = "${var.cluster_name}-nat-sg"
    }
  )

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_instance" "nat" {
  ami                    = data.aws_ami.nat.id
  instance_type          = "t3.nano"
  subnet_id              = aws_subnet.public[var.availability_zones[0]].id
  vpc_security_group_ids = [aws_security_group.nat.id]
  source_dest_check      = false # NAT Instance 필수: 자기 IP가 아닌 패킷도 전달

  user_data = <<-USERDATA
    #!/bin/bash
    set -e

    # IP forwarding 활성화
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    sysctl -w net.ipv4.ip_forward=1

    # iptables NAT 설정 — VPC 전체 CIDR에 대해 MASQUERADE
    PUB_IF=$(ip route | grep default | awk '{print $5}')
    iptables -t nat -A POSTROUTING -o $PUB_IF -s ${var.vpc_cidr} -j MASQUERADE
    iptables -A FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    iptables -A FORWARD -s ${var.vpc_cidr} -o $PUB_IF -j ACCEPT

    # iptables 영구 저장
    yum install -y iptables-services 2>/dev/null || true
    iptables-save > /etc/sysconfig/iptables 2>/dev/null || true
    systemctl enable iptables 2>/dev/null || true
  USERDATA

  monitoring = true # Detailed CloudWatch (1분 간격) — 카오스 실험 관측용

  tags = merge(
    var.tags,
    {
      Name = "${var.cluster_name}-nat"
      Role = "nat" # FIS 타겟팅용 태그
    }
  )

  depends_on = [aws_internet_gateway.this]
}

resource "aws_route" "private_default" {
  for_each = toset(var.availability_zones)

  route_table_id         = aws_route_table.private[each.key].id
  destination_cidr_block = "0.0.0.0/0"
  network_interface_id   = aws_instance.nat.primary_network_interface_id
}

resource "aws_route_table_association" "control_plane" {
  for_each = aws_subnet.control_plane

  subnet_id      = each.value.id
  route_table_id = aws_route_table.private[each.key].id
}

resource "aws_route_table_association" "worker" {
  for_each = aws_subnet.worker

  subnet_id      = each.value.id
  route_table_id = aws_route_table.private[each.key].id
}

output "private_route_table_ids" {
  description = "Private route table IDs (one per AZ) used by control-plane and worker subnets"
  value       = [for rt in aws_route_table.private : rt.id]
}

output "vpc_id" {
  value = aws_vpc.this.id
}

output "vpc_cidr" {
  value = aws_vpc.this.cidr_block
}

output "public_subnet_ids" {
  value = { for az, subnet in aws_subnet.public : az => subnet.id }
}

output "control_plane_subnet_ids" {
  value = { for az, subnet in aws_subnet.control_plane : az => subnet.id }
}

output "control_plane_subnet_cidrs" {
  value = local.control_plane_subnet_cidrs
}

output "worker_subnet_ids" {
  value = { for az, subnet in aws_subnet.worker : az => subnet.id }
}

output "nat_instance_id" {
  description = "NAT Instance ID (FIS chaos experiment target)"
  value       = aws_instance.nat.id
}

output "nat_instance_private_ip" {
  description = "NAT Instance private IP"
  value       = aws_instance.nat.private_ip
}
