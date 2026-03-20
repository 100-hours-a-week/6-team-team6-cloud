variable "project_name" {
  type = string
}

variable "env" {
  type = string
}

variable "cluster_name" {
  type = string
}

variable "ami_id" {
  type = string
}

variable "control_plane_endpoint" {
  type = string
}

variable "kubernetes_version" {
  type = string
}

variable "kubernetes_minor_version" {
  type = string
}

variable "pod_network_cidr" {
  type = string
}

variable "service_cidr" {
  type = string
}

variable "cluster_dns_ip" {
  type = string
}

variable "availability_zones" {
  type = list(string)
}

variable "private_dns_zone_name" {
  type = string
}

variable "control_plane_subnet_ids" {
  type = map(string)
}

variable "control_plane_subnet_cidrs" {
  type = map(string)
}

variable "worker_subnet_ids" {
  type = map(string)
}

variable "instance_profile_name" {
  type = string
}

variable "cluster_mesh_security_group_id" {
  type = string
}

variable "control_plane_security_group_id" {
  type = string
}

variable "app_security_group_id" {
  type = string
}

variable "data_security_group_id" {
  type = string
}

variable "enable_ssh" {
  type = bool
}

variable "key_name" {
  type    = string
  default = null
}

variable "control_plane_instance_type" {
  type = string
}

variable "app_instance_type" {
  type = string
}

variable "data_instance_type" {
  type = string
}

variable "control_plane_root_volume_size" {
  type = number
}

variable "app_root_volume_size" {
  type = number
}

variable "data_root_volume_size" {
  type = number
}

variable "tags" {
  type = map(string)
}

locals {
  control_plane_nodes = {
    for idx, az in var.availability_zones : format("cp-%02d", idx + 1) => {
      az         = az
      subnet_id  = var.control_plane_subnet_ids[az]
      private_ip = cidrhost(var.control_plane_subnet_cidrs[az], 10)
      hostname   = format("%s-cp-%02d", var.cluster_name, idx + 1)
      labels     = "node-group=control-plane,workload-plane=control-plane"
      taints = [
        {
          key    = "node-role.kubernetes.io/control-plane"
          value  = ""
          effect = "NoSchedule"
        }
      ]
    }
  }

  app_nodes = {
    for idx in range(4) : format("app-%02d", idx + 1) => {
      az        = var.availability_zones[idx % length(var.availability_zones)]
      subnet_id = var.worker_subnet_ids[var.availability_zones[idx % length(var.availability_zones)]]
      hostname  = format("%s-app-%02d", var.cluster_name, idx + 1)
      labels    = "node-role=app,node-group=app,workload-plane=app"
      taints    = []
    }
  }

  data_nodes = {
    for idx in range(3) : format("data-%02d", idx + 1) => {
      az        = var.availability_zones[idx % length(var.availability_zones)]
      subnet_id = var.worker_subnet_ids[var.availability_zones[idx % length(var.availability_zones)]]
      hostname  = format("%s-data-%02d", var.cluster_name, idx + 1)
      labels    = "node-role=data,node-group=data,workload-plane=data"
      taints = [
        {
          key    = "workload-plane"
          value  = "data"
          effect = "NoSchedule"
        }
      ]
    }
  }

  bootstrap_common_script = templatefile("${path.module}/../../templates/bootstrap-common.sh.tftpl", {
    kubernetes_minor_version = var.kubernetes_minor_version
  })

  control_plane_init_script = templatefile("${path.module}/../../templates/ssm-control-plane-init.sh.tftpl", {
    control_plane_endpoint = var.control_plane_endpoint
  })

  control_plane_join_script = templatefile("${path.module}/../../templates/ssm-control-plane-join.sh.tftpl", {})

  worker_join_script = templatefile("${path.module}/../../templates/ssm-worker-join.sh.tftpl", {})

  write_join_env_script = templatefile("${path.module}/../../templates/ssm-write-join-env.sh.tftpl", {})
}

resource "aws_instance" "control_plane" {
  for_each = local.control_plane_nodes

  ami                         = var.ami_id
  instance_type               = var.control_plane_instance_type
  subnet_id                   = each.value.subnet_id
  private_ip                  = each.value.private_ip
  iam_instance_profile        = var.instance_profile_name
  vpc_security_group_ids      = [var.cluster_mesh_security_group_id, var.control_plane_security_group_id]
  associate_public_ip_address = true
  key_name                    = var.enable_ssh ? var.key_name : null
  monitoring                  = true
  source_dest_check           = false

  lifecycle {
    ignore_changes = [ami, associate_public_ip_address]
  }

  user_data = each.key == "cp-01" ? templatefile("${path.module}/../../templates/cloud-init-control-plane-init.yaml.tftpl", {
    node_hostname             = each.value.hostname
    private_dns_zone_name     = var.private_dns_zone_name
    bootstrap_common_script   = local.bootstrap_common_script
    control_plane_init_script = local.control_plane_init_script
    write_join_env_script     = local.write_join_env_script
    kubeadm_init_config = templatefile("${path.module}/../../templates/kubeadm-init-config.yaml.tftpl", {
      advertise_address      = each.value.private_ip
      node_name              = each.value.hostname
      node_labels            = each.value.labels
      node_taints            = each.value.taints
      cluster_name           = var.cluster_name
      kubernetes_version     = var.kubernetes_version
      control_plane_endpoint = var.control_plane_endpoint
      pod_network_cidr       = var.pod_network_cidr
      service_cidr           = var.service_cidr
      cluster_dns_ip         = var.cluster_dns_ip
    })
    }) : templatefile("${path.module}/../../templates/cloud-init-control-plane-join.yaml.tftpl", {
    node_hostname             = each.value.hostname
    private_dns_zone_name     = var.private_dns_zone_name
    bootstrap_common_script   = local.bootstrap_common_script
    control_plane_join_script = local.control_plane_join_script
    write_join_env_script     = local.write_join_env_script
    kubeadm_join_control_plane_config = templatefile("${path.module}/../../templates/kubeadm-join-control-plane-config.yaml.tftpl", {
      control_plane_endpoint = var.control_plane_endpoint
      node_labels            = each.value.labels
      node_taints            = each.value.taints
    })
  })

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  root_block_device {
    volume_size           = var.control_plane_root_volume_size
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  tags = merge(
    var.tags,
    {
      Name     = each.value.hostname
      NodeRole = "control-plane"
      Tier     = "control-plane"
    }
  )
}

resource "aws_instance" "app" {
  for_each = local.app_nodes

  ami                         = var.ami_id
  instance_type               = var.app_instance_type
  subnet_id                   = each.value.subnet_id
  iam_instance_profile        = var.instance_profile_name
  vpc_security_group_ids      = [var.cluster_mesh_security_group_id, var.app_security_group_id]
  associate_public_ip_address = true
  key_name                    = var.enable_ssh ? var.key_name : null
  monitoring                  = true
  source_dest_check           = false

  lifecycle {
    ignore_changes = [ami, associate_public_ip_address]
  }

  user_data = templatefile("${path.module}/../../templates/cloud-init-worker-join.yaml.tftpl", {
    node_hostname           = each.value.hostname
    private_dns_zone_name   = var.private_dns_zone_name
    bootstrap_common_script = local.bootstrap_common_script
    worker_join_script      = local.worker_join_script
    write_join_env_script   = local.write_join_env_script
    kubeadm_join_worker_config = templatefile("${path.module}/../../templates/kubeadm-join-worker-config.yaml.tftpl", {
      control_plane_endpoint = var.control_plane_endpoint
      node_labels            = each.value.labels
      node_taints            = each.value.taints
    })
  })

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  root_block_device {
    volume_size           = var.app_root_volume_size
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  tags = merge(
    var.tags,
    {
      Name     = each.value.hostname
      NodeRole = "app"
      Tier     = "worker"
    }
  )
}

resource "aws_instance" "data" {
  for_each = local.data_nodes

  ami                         = var.ami_id
  instance_type               = var.data_instance_type
  subnet_id                   = each.value.subnet_id
  iam_instance_profile        = var.instance_profile_name
  vpc_security_group_ids      = [var.cluster_mesh_security_group_id, var.data_security_group_id]
  associate_public_ip_address = true
  key_name                    = var.enable_ssh ? var.key_name : null
  monitoring                  = true
  source_dest_check           = false

  lifecycle {
    ignore_changes = [ami, associate_public_ip_address]
  }

  user_data = templatefile("${path.module}/../../templates/cloud-init-worker-join.yaml.tftpl", {
    node_hostname           = each.value.hostname
    private_dns_zone_name   = var.private_dns_zone_name
    bootstrap_common_script = local.bootstrap_common_script
    worker_join_script      = local.worker_join_script
    write_join_env_script   = local.write_join_env_script
    kubeadm_join_worker_config = templatefile("${path.module}/../../templates/kubeadm-join-worker-config.yaml.tftpl", {
      control_plane_endpoint = var.control_plane_endpoint
      node_labels            = each.value.labels
      node_taints            = each.value.taints
    })
  })

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  root_block_device {
    volume_size           = var.data_root_volume_size
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  tags = merge(
    var.tags,
    {
      Name     = each.value.hostname
      NodeRole = "data"
      Tier     = "worker"
    }
  )
}

output "control_plane_instance_ids" {
  value = { for name, instance in aws_instance.control_plane : name => instance.id }
}

output "control_plane_private_ips" {
  value = { for name, instance in aws_instance.control_plane : name => instance.private_ip }
}

output "app_instance_ids" {
  value = { for name, instance in aws_instance.app : name => instance.id }
}

output "app_private_ips" {
  value = { for name, instance in aws_instance.app : name => instance.private_ip }
}

output "data_instance_ids" {
  value = { for name, instance in aws_instance.data : name => instance.id }
}

output "data_private_ips" {
  value = { for name, instance in aws_instance.data : name => instance.private_ip }
}
