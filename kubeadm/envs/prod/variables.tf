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

variable "chaos_alarm_email" {
  description = "Email address for chaos engineering experiment notifications"
  type        = string
  default     = ""
}

variable "rds_fault_injection_namespace" {
  description = "Namespace where RDS fault injection support resources are deployed"
  type        = string
  default     = "billage-app"
}

variable "rds_fault_injection_toxiproxy_image" {
  description = "Container image used for the Toxiproxy deployment"
  type        = string
  default     = "ghcr.io/shopify/toxiproxy:2.12.0"
}

variable "rds_fault_injection_proxy_name" {
  description = "Logical Toxiproxy proxy name for the RDS upstream"
  type        = string
  default     = "rds-upstream"
}

variable "rds_fault_injection_listen_port" {
  description = "Listen port exposed by Toxiproxy for the RDS proxy"
  type        = number
  default     = 3306
}

variable "rds_fault_injection_upstream_host" {
  description = "RDS hostname that Toxiproxy forwards traffic to"
  type        = string
  default     = ""
}

variable "rds_fault_injection_upstream_port" {
  description = "RDS port that Toxiproxy forwards traffic to"
  type        = number
  default     = 3306
}

variable "rds_fault_injection_upstream_cidr" {
  description = "CIDR allowed for Toxiproxy egress toward the upstream RDS network"
  type        = string
  default     = "10.0.0.0/16"
}

variable "rds_fault_injection_probe_path" {
  description = "HTTP path used by the sample k6 script to probe the Spring service"
  type        = string
  default     = "/actuator/health"
}

variable "rds_fault_injection_spring_service_name" {
  description = "Spring service name referenced by the sample k6 script"
  type        = string
  default     = "spring-boot"
}

variable "rds_fault_injection_spring_service_port" {
  description = "Spring service port referenced by the sample k6 script"
  type        = number
  default     = 8080
}

variable "rds_fault_injection_spring_deployment_name" {
  description = "Spring deployment name that should be rolled to the kube fault injection image"
  type        = string
  default     = "spring-boot"
}

variable "rds_fault_injection_spring_container_name" {
  description = "Spring container name inside the deployment that should be updated"
  type        = string
  default     = "spring-boot"
}

variable "rds_fault_injection_ecr_repository" {
  description = "ECR repository that stores the Spring backend image used by the kube fault injection deployment"
  type        = string
  default     = "billage-be"
}

variable "rds_fault_injection_image_tag" {
  description = "ECR image tag that the kube fault injection rollout should pull"
  type        = string
  default     = "kube_latest"
}

variable "rds_fault_injection_datasource_url" {
  description = "Datasource URL injected into the Spring deployment for RDS fault injection. In the current cluster this overrides DEV_DB_URL and should point to the toxiproxy-rds service."
  type        = string
  default     = ""
}

variable "rds_fault_injection_probe_liveness_path" {
  description = "Liveness probe path applied by the resilience patch"
  type        = string
  default     = "/actuator/health/liveness"
}

variable "rds_fault_injection_probe_readiness_path" {
  description = "Readiness probe path applied by the resilience patch"
  type        = string
  default     = "/actuator/health/readiness"
}

variable "rds_fault_injection_probe_startup_path" {
  description = "Startup probe path applied by the resilience patch"
  type        = string
  default     = "/actuator/health/liveness"
}

variable "rds_fault_injection_probe_timeout_seconds" {
  description = "Timeout seconds applied to all Spring HTTP probes by the resilience patch"
  type        = number
  default     = 5
}

variable "rds_fault_injection_startup_failure_threshold" {
  description = "Startup probe failure threshold used by the resilience patch"
  type        = number
  default     = 60
}

variable "rds_fault_injection_spring_request_cpu" {
  description = "CPU request applied to the Spring container by the resilience patch"
  type        = string
  default     = "300m"
}

variable "rds_fault_injection_hpa_scale_down_stabilization_window_seconds" {
  description = "Scale-down stabilization window applied to the Spring HPA by the resilience patch"
  type        = number
  default     = 60
}
