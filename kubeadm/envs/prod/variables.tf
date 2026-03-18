variable "aws_region" {
  description = "AWS region for the kubeadm cluster"
  type        = string
  default     = "ap-northeast-2"
}

variable "project_name" {
  description = "Project name used in tags and resource names"
  type        = string
  default     = "billage"
}

variable "env" {
  description = "Environment name"
  type        = string
  default     = "prod"
}

variable "cluster_name" {
  description = "Cluster name prefix"
  type        = string
  default     = "billage-kubeadm-prod"
}

variable "vpc_cidr" {
  description = "CIDR block for the dedicated kubeadm VPC"
  type        = string
}

variable "availability_zones" {
  description = "Exactly three availability zones for control-plane and worker distribution"
  type        = list(string)
  default     = ["ap-northeast-2a", "ap-northeast-2b", "ap-northeast-2c"]

  validation {
    condition     = length(var.availability_zones) == 3
    error_message = "availability_zones must contain exactly three AZs."
  }
}

variable "management_cidrs" {
  description = "CIDR blocks allowed to reach the kube-apiserver and optional SSH"
  type        = list(string)
  default     = []
}

variable "enable_ssh" {
  description = "Whether to open SSH access on cluster nodes"
  type        = bool
  default     = false
}

variable "ssh_allowed_cidrs" {
  description = "Additional CIDR blocks allowed for SSH when enable_ssh is true"
  type        = list(string)
  default     = []
}

variable "key_name" {
  description = "Existing EC2 key pair name used when enable_ssh is true"
  type        = string
  default     = null
}

variable "control_plane_instance_type" {
  description = "Instance type for control-plane nodes"
  type        = string
  default     = "m7i.large"
}

variable "app_instance_type" {
  description = "Instance type for app worker nodes"
  type        = string
  default     = "m7i-flex.large"
}

variable "data_instance_type" {
  description = "Instance type for data worker nodes"
  type        = string
  default     = "m7i.large"
}

variable "control_plane_root_volume_size" {
  description = "Root EBS size in GiB for control-plane nodes"
  type        = number
  default     = 50
}

variable "app_root_volume_size" {
  description = "Root EBS size in GiB for app nodes"
  type        = number
  default     = 80
}

variable "data_root_volume_size" {
  description = "Root EBS size in GiB for data nodes"
  type        = number
  default     = 80
}

variable "private_dns_zone_name" {
  description = "Private hosted zone name for internal kubeadm endpoints"
  type        = string
  default     = "village.internal"
}

variable "kube_apiserver_record_name" {
  description = "Record name inside the private hosted zone for the kube-apiserver endpoint"
  type        = string
  default     = "k8s-api"
}

variable "additional_tags" {
  description = "Additional tags merged into resources"
  type        = map(string)
  default     = {}
}

variable "kubernetes_version" {
  description = "Kubernetes version for kubeadm config"
  type        = string
  default     = "v1.28.0"
}

variable "kubernetes_minor_version" {
  description = "Minor Kubernetes stream used for apt repository"
  type        = string
  default     = "v1.28"
}

variable "pod_network_cidr" {
  description = "Pod network CIDR passed to kubeadm cluster configuration"
  type        = string
  default     = "192.168.0.0/16"
}

variable "service_cidr" {
  description = "Service network CIDR passed to kubeadm cluster configuration"
  type        = string
  default     = "10.96.0.0/12"
}

variable "cluster_dns_ip" {
  description = "Cluster DNS service IP used in kubelet configuration"
  type        = string
  default     = "10.96.0.10"
}

variable "public_edge_host" {
  description = "Public hostname served through the ingress-nginx and ALB entrypoint"
  type        = string
}

variable "cert_manager_email" {
  description = "Email address used for cert-manager ACME registrations"
  type        = string
}

variable "alb_certificate_arn" {
  description = "ACM certificate ARN attached to the internet-facing ALB"
  type        = string
}

variable "cert_manager_acme_server" {
  description = "ACME directory URL used by cert-manager"
  type        = string
  default     = "https://acme-v02.api.letsencrypt.org/directory"
}

variable "calico_version" {
  description = "Calico release used for tigera-operator bootstrap"
  type        = string
  default     = "v3.31.0"
}

variable "calico_bgp_as_number" {
  description = "Private AS number advertised by Calico node-to-node mesh"
  type        = number
  default     = 64512
}

variable "ingress_nginx_chart_version" {
  description = "Ingress-NGINX Helm chart version"
  type        = string
  default     = "4.15.0"
}

variable "cert_manager_chart_version" {
  description = "cert-manager Helm chart version"
  type        = string
  default     = "v1.19.4"
}

variable "aws_load_balancer_controller_chart_version" {
  description = "AWS Load Balancer Controller Helm chart version"
  type        = string
  default     = "3.1.0"
}
