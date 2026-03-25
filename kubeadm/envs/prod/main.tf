locals {
  common_tags = merge(
    {
      Project     = var.project_name
      Environment = var.env
      ManagedBy   = "terraform"
      Platform    = "kubeadm"
      Cluster     = var.cluster_name
      Stack       = "infra"
    },
    var.additional_tags
  )
}

data "aws_caller_identity" "current" {}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name = "name"
    # Pin to 20260218 build — 20260313 build causes kubelet restart race condition
    # during kubeadm init, leading to etcd/apiserver CrashLoopBackOff.
    # See: docs/runbook/2026-03-18-cp-crashloop-troubleshooting.md
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-20260218*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

module "network" {
  source = "./modules/network"

  project_name       = var.project_name
  env                = var.env
  cluster_name       = var.cluster_name
  vpc_cidr           = var.vpc_cidr
  availability_zones = var.availability_zones
  tags               = local.common_tags
}

module "iam" {
  source = "./modules/iam"

  project_name = var.project_name
  env          = var.env
  cluster_name = var.cluster_name
  tags         = local.common_tags
}

module "security" {
  source = "./modules/security"

  project_name      = var.project_name
  env               = var.env
  cluster_name      = var.cluster_name
  vpc_id            = module.network.vpc_id
  vpc_cidr          = module.network.vpc_cidr
  management_cidrs  = var.management_cidrs
  enable_ssh        = var.enable_ssh
  ssh_allowed_cidrs = var.ssh_allowed_cidrs
  tags              = local.common_tags
}

module "compute" {
  source = "./modules/compute"

  project_name                    = var.project_name
  env                             = var.env
  cluster_name                    = var.cluster_name
  ami_id                          = data.aws_ami.ubuntu.id
  control_plane_endpoint          = "${var.kube_apiserver_record_name}.${var.private_dns_zone_name}"
  kubernetes_version              = var.kubernetes_version
  kubernetes_minor_version        = var.kubernetes_minor_version
  pod_network_cidr                = var.pod_network_cidr
  service_cidr                    = var.service_cidr
  cluster_dns_ip                  = var.cluster_dns_ip
  availability_zones              = var.availability_zones
  private_dns_zone_name           = var.private_dns_zone_name
  control_plane_subnet_ids        = module.network.control_plane_subnet_ids
  control_plane_subnet_cidrs      = module.network.control_plane_subnet_cidrs
  worker_subnet_ids               = module.network.worker_subnet_ids
  instance_profile_name           = module.iam.instance_profile_name
  cluster_mesh_security_group_id  = module.security.cluster_mesh_security_group_id
  control_plane_security_group_id = module.security.control_plane_security_group_id
  app_security_group_id           = module.security.app_security_group_id
  data_security_group_id          = module.security.data_security_group_id
  enable_ssh                      = var.enable_ssh
  key_name                        = var.key_name
  control_plane_instance_type     = var.control_plane_instance_type
  app_instance_type               = var.app_instance_type
  data_instance_type              = var.data_instance_type
  control_plane_root_volume_size  = var.control_plane_root_volume_size
  app_root_volume_size            = var.app_root_volume_size
  data_root_volume_size           = var.data_root_volume_size
  tags                            = local.common_tags
}

module "api_endpoint" {
  source = "./modules/api-endpoint"

  cluster_name               = var.cluster_name
  vpc_id                     = module.network.vpc_id
  control_plane_subnet_ids   = module.network.control_plane_subnet_ids
  control_plane_instance_ids = module.compute.control_plane_instance_ids
  private_dns_zone_name      = var.private_dns_zone_name
  kube_apiserver_record_name = var.kube_apiserver_record_name
  tags                       = local.common_tags
}

module "chaos" {
  source = "./modules/chaos"

  cluster_name    = var.cluster_name
  env             = var.env
  nat_instance_id = module.network.nat_instance_id
  alarm_email     = var.chaos_alarm_email
  tags            = local.common_tags
}

locals {
  calico_kubernetes_service_host = lookup(
    module.compute.control_plane_private_ips,
    "cp-01",
    "${var.kube_apiserver_record_name}.${var.private_dns_zone_name}"
  )

  platform_bootstrap_script = templatefile("${path.module}/templates/ssm-platform-bootstrap.sh.tftpl", {
    cluster_name                   = var.cluster_name
    aws_region                     = var.aws_region
    vpc_id                         = module.network.vpc_id
    control_plane_endpoint         = "${var.kube_apiserver_record_name}.${var.private_dns_zone_name}"
    calico_kubernetes_service_host = local.calico_kubernetes_service_host
    private_route_table_ids        = join(",", module.network.private_route_table_ids)
    public_edge_host               = var.public_edge_host
    cert_manager_email             = var.cert_manager_email
    cert_manager_acme_server       = var.cert_manager_acme_server
    alb_certificate_arn            = var.alb_certificate_arn
    calico_version                 = var.calico_version
    calico_bgp_as_number           = var.calico_bgp_as_number
    pod_network_cidr               = var.pod_network_cidr
    ingress_nginx_chart_version    = var.ingress_nginx_chart_version
    cert_manager_chart_version     = var.cert_manager_chart_version
    aws_lbc_chart_version          = var.aws_load_balancer_controller_chart_version
  })

  rds_fault_injection_bootstrap_script = templatefile("${path.module}/templates/ssm-rds-fault-injection-bootstrap.sh.tftpl", {
    cluster_name        = var.cluster_name
    namespace           = var.rds_fault_injection_namespace
    toxiproxy_image     = var.rds_fault_injection_toxiproxy_image
    proxy_name          = var.rds_fault_injection_proxy_name
    listen_port         = var.rds_fault_injection_listen_port
    upstream_host       = var.rds_fault_injection_upstream_host
    upstream_port       = var.rds_fault_injection_upstream_port
    rds_egress_cidr     = var.rds_fault_injection_upstream_cidr
    probe_path          = var.rds_fault_injection_probe_path
    spring_service_name = var.rds_fault_injection_spring_service_name
    spring_service_port = var.rds_fault_injection_spring_service_port
  })

  rds_fault_injection_rollout_script = templatefile("${path.module}/templates/ssm-rds-fault-injection-rollout.sh.tftpl", {
    namespace       = var.rds_fault_injection_namespace
    deployment_name = var.rds_fault_injection_spring_deployment_name
    container_name  = var.rds_fault_injection_spring_container_name
    image           = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com/${var.rds_fault_injection_ecr_repository}:${var.rds_fault_injection_image_tag}"
    datasource_url  = var.rds_fault_injection_datasource_url
  })

  rds_fault_injection_resilience_patch_script = templatefile("${path.module}/templates/ssm-rds-fault-injection-resilience-patch.sh.tftpl", {
    namespace                 = var.rds_fault_injection_namespace
    deployment_name           = var.rds_fault_injection_spring_deployment_name
    container_name            = var.rds_fault_injection_spring_container_name
    liveness_path             = var.rds_fault_injection_probe_liveness_path
    readiness_path            = var.rds_fault_injection_probe_readiness_path
    startup_path              = var.rds_fault_injection_probe_startup_path
    probe_timeout_seconds     = var.rds_fault_injection_probe_timeout_seconds
    startup_failure_threshold = var.rds_fault_injection_startup_failure_threshold
    request_cpu               = var.rds_fault_injection_spring_request_cpu
    hpa_scale_down_window     = var.rds_fault_injection_hpa_scale_down_stabilization_window_seconds
  })
}

resource "aws_ssm_document" "platform_bootstrap" {
  name            = "${var.cluster_name}-platform-bootstrap"
  document_type   = "Command"
  document_format = "YAML"

  content = yamlencode({
    schemaVersion = "2.2"
    description   = "Bootstrap Calico, namespaces, RBAC, network policies, ingress-nginx, AWS Load Balancer Controller, and cert-manager on the kubeadm prod cluster."
    mainSteps = [
      {
        action = "aws:runShellScript"
        name   = "platformBootstrap"
        inputs = {
          runCommand = split("\n", local.platform_bootstrap_script)
        }
      }
    ]
  })

  tags = merge(
    local.common_tags,
    {
      Name = "${var.cluster_name}-platform-bootstrap"
    }
  )
}

resource "aws_ssm_document" "rds_fault_injection_bootstrap" {
  name            = "${var.cluster_name}-rds-fault-injection-bootstrap"
  document_type   = "Command"
  document_format = "YAML"

  content = yamlencode({
    schemaVersion = "2.2"
    description   = "Deploy Toxiproxy and supporting policies/scripts for RDS fault injection experiments on the kubeadm prod cluster."
    mainSteps = [
      {
        action = "aws:runShellScript"
        name   = "rdsFaultInjectionBootstrap"
        inputs = {
          runCommand = split("\n", local.rds_fault_injection_bootstrap_script)
        }
      }
    ]
  })

  tags = merge(
    local.common_tags,
    {
      Name = "${var.cluster_name}-rds-fault-injection-bootstrap"
    }
  )
}

resource "aws_ssm_document" "rds_fault_injection_rollout" {
  name            = "${var.cluster_name}-rds-fault-injection-rollout"
  document_type   = "Command"
  document_format = "YAML"

  content = yamlencode({
    schemaVersion = "2.2"
    description   = "Patch the Spring deployment to pull the kube_latest image for RDS fault injection experiments."
    mainSteps = [
      {
        action = "aws:runShellScript"
        name   = "rdsFaultInjectionRollout"
        inputs = {
          runCommand = split("\n", local.rds_fault_injection_rollout_script)
        }
      }
    ]
  })

  tags = merge(
    local.common_tags,
    {
      Name = "${var.cluster_name}-rds-fault-injection-rollout"
    }
  )
}

resource "aws_ssm_document" "rds_fault_injection_resilience_patch" {
  name            = "${var.cluster_name}-rds-fault-injection-resilience-patch"
  document_type   = "Command"
  document_format = "YAML"

  content = yamlencode({
    schemaVersion = "2.2"
    description   = "Patch Spring probes, resource requests, and HPA scale-down behavior to improve recovery during RDS fault injection experiments."
    mainSteps = [
      {
        action = "aws:runShellScript"
        name   = "rdsFaultInjectionResiliencePatch"
        inputs = {
          runCommand = split("\n", local.rds_fault_injection_resilience_patch_script)
        }
      }
    ]
  })

  tags = merge(
    local.common_tags,
    {
      Name = "${var.cluster_name}-rds-fault-injection-resilience-patch"
    }
  )
}
