# modules/vpc-peering/outputs.tf

output "peering_connection_id" {
  description = "VPC Peering Connection ID"
  value       = aws_vpc_peering_connection.main.id
}

output "peering_connection_status" {
  description = "VPC Peering Connection Status"
  value       = aws_vpc_peering_connection.main.accept_status
}
