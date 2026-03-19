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

resource "aws_eip" "nat" {
  domain = "vpc"

  tags = merge(
    var.tags,
    {
      Name = "${var.cluster_name}-nat-eip"
    }
  )
}

resource "aws_nat_gateway" "this" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[var.availability_zones[0]].id

  tags = merge(
    var.tags,
    {
      Name = "${var.cluster_name}-nat-gw"
    }
  )

  depends_on = [aws_internet_gateway.this]
}

resource "aws_route" "private_default" {
  for_each = toset(var.availability_zones)

  route_table_id         = aws_route_table.private[each.key].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this.id
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

output "nat_gateway_id" {
  value = aws_nat_gateway.this.id
}
