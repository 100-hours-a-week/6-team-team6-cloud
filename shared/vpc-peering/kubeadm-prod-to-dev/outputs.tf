# shared/vpc-peering/kubeadm-prod-to-dev/outputs.tf

output "peering_connection_id" {
  description = "VPC Peering Connection ID"
  value       = aws_vpc_peering_connection.kubeadm_prod_to_dev.id
}

output "peering_connection_status" {
  description = "VPC Peering Connection Status"
  value       = aws_vpc_peering_connection.kubeadm_prod_to_dev.accept_status
}
