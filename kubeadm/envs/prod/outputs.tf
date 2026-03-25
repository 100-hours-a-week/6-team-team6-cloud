output "vpc_id" {
  description = "Dedicated kubeadm VPC ID"
  value       = module.network.vpc_id
}

output "vpc_cidr" {
  description = "Dedicated kubeadm VPC CIDR"
  value       = module.network.vpc_cidr
}

output "public_subnet_ids" {
  description = "Public subnet IDs keyed by AZ"
  value       = module.network.public_subnet_ids
}

output "control_plane_subnet_ids" {
  description = "Control-plane subnet IDs keyed by AZ"
  value       = module.network.control_plane_subnet_ids
}

output "worker_subnet_ids" {
  description = "Worker subnet IDs keyed by AZ"
  value       = module.network.worker_subnet_ids
}

output "instance_profile_name" {
  description = "IAM instance profile name attached to all kubeadm nodes"
  value       = module.iam.instance_profile_name
}

output "instance_role_name" {
  description = "IAM role name attached to all kubeadm nodes"
  value       = module.iam.role_name
}

output "cluster_mesh_security_group_id" {
  description = "Shared cluster mesh security group ID"
  value       = module.security.cluster_mesh_security_group_id
}

output "control_plane_security_group_id" {
  description = "Control-plane security group ID"
  value       = module.security.control_plane_security_group_id
}

output "app_security_group_id" {
  description = "App worker security group ID"
  value       = module.security.app_security_group_id
}

output "data_security_group_id" {
  description = "Data worker security group ID"
  value       = module.security.data_security_group_id
}

output "control_plane_instance_ids" {
  description = "Control-plane instance IDs keyed by node name"
  value       = module.compute.control_plane_instance_ids
}

output "control_plane_private_ips" {
  description = "Control-plane private IPs keyed by node name"
  value       = module.compute.control_plane_private_ips
}

output "app_instance_ids" {
  description = "App node instance IDs keyed by node name"
  value       = module.compute.app_instance_ids
}

output "app_private_ips" {
  description = "App node private IPs keyed by node name"
  value       = module.compute.app_private_ips
}

output "data_instance_ids" {
  description = "Data node instance IDs keyed by node name"
  value       = module.compute.data_instance_ids
}

output "data_private_ips" {
  description = "Data node private IPs keyed by node name"
  value       = module.compute.data_private_ips
}

output "kube_apiserver_fqdn" {
  description = "Private DNS name for the kube-apiserver endpoint"
  value       = module.api_endpoint.kube_apiserver_fqdn
}

output "kube_apiserver_nlb_dns_name" {
  description = "Internal NLB DNS name for the kube-apiserver endpoint"
  value       = module.api_endpoint.nlb_dns_name
}

output "private_hosted_zone_id" {
  description = "Private hosted zone ID for the internal cluster domain"
  value       = module.api_endpoint.private_hosted_zone_id
}

output "public_edge_host" {
  description = "Public hostname expected to route through the ALB and ingress-nginx edge path"
  value       = var.public_edge_host
}

output "platform_bootstrap_ssm_document_name" {
  description = "SSM document name used to apply Calico, namespaces, policies, and edge controllers after all nodes join"
  value       = aws_ssm_document.platform_bootstrap.name
}

output "rds_fault_injection_bootstrap_ssm_document_name" {
  description = "SSM document name used to deploy Toxiproxy and supporting resources for RDS fault injection"
  value       = aws_ssm_document.rds_fault_injection_bootstrap.name
}

output "rds_fault_injection_rollout_ssm_document_name" {
  description = "SSM document name used to patch the Spring deployment to the kube_latest image for RDS fault injection"
  value       = aws_ssm_document.rds_fault_injection_rollout.name
}

output "nat_instance_id" {
  description = "NAT Instance ID — FIS chaos experiment target"
  value       = module.network.nat_instance_id
}
