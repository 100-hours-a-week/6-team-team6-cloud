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

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
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

locals {
  platform_bootstrap_script = templatefile("${path.module}/templates/ssm-platform-bootstrap.sh.tftpl", {
    cluster_name                = var.cluster_name
    aws_region                  = var.aws_region
    vpc_id                      = module.network.vpc_id
    control_plane_endpoint      = "${var.kube_apiserver_record_name}.${var.private_dns_zone_name}"
    public_edge_host            = var.public_edge_host
    cert_manager_email          = var.cert_manager_email
    cert_manager_acme_server    = var.cert_manager_acme_server
    alb_certificate_arn         = var.alb_certificate_arn
    calico_version              = var.calico_version
    calico_bgp_as_number        = var.calico_bgp_as_number
    pod_network_cidr            = var.pod_network_cidr
    ingress_nginx_chart_version = var.ingress_nginx_chart_version
    cert_manager_chart_version  = var.cert_manager_chart_version
    aws_lbc_chart_version       = var.aws_load_balancer_controller_chart_version
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
