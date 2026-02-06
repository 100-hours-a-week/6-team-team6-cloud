# modules/vpc/outputs.tf

output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.main.id
}

output "vpc_cidr" {
  description = "VPC CIDR 블록"
  value       = aws_vpc.main.cidr_block
}

output "public_subnet_id" {
  description = "Public Subnet ID"
  value       = aws_subnet.public.id
}

output "internet_gateway_id" {
  description = "Internet Gateway ID"
  value       = aws_internet_gateway.main.id
}

output "public_route_table_id" {
  description = "Public Route Table ID"
  value       = aws_route_table.public.id
}

output "private_subnet_id" {
  description = "Private Subnet ID (생성된 경우)"
  value       = var.private_subnet_cidr != "" ? aws_subnet.private[0].id : null
}

output "private_route_table_id" {
  description = "Private Route Table ID (생성된 경우)"
  value       = var.private_subnet_cidr != "" ? aws_route_table.private[0].id : null
}
