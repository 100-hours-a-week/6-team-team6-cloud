packer {
  required_plugins {
    amazon = {
      version = ">= 1.2.0"
      source  = "github.com/hashicorp/amazon"
    }
  }
}

locals {
  timestamp = formatdate("YYYYMMDD-hhmmss", timestamp())
  ami_name  = "${var.ami_name_prefix}-${local.timestamp}"
}

source "amazon-ebs" "ubuntu" {
  ami_name        = local.ami_name
  ami_description = "Billage Golden AMI - Common base image for Spring Boot, FastAPI, Next.js"
  instance_type   = var.instance_type
  region          = var.aws_region

  source_ami_filter {
    filters = {
      name                = var.source_ami_filter_name
      root-device-type    = "ebs"
      virtualization-type = "hvm"
      architecture        = "x86_64"
    }
    owners      = [var.source_ami_owner]
    most_recent = true
  }

  ssh_username = var.ssh_username

  # Optional: VPC/Subnet configuration
  vpc_id    = var.vpc_id != "" ? var.vpc_id : null
  subnet_id = var.subnet_id != "" ? var.subnet_id : null

  # Associate public IP for connectivity
  associate_public_ip_address = true

  # Tags for the AMI and snapshots
  tags = merge(var.tags, {
    Name      = local.ami_name
    BuildTime = local.timestamp
  })

  snapshot_tags = var.tags

  # Launch block device configuration
  launch_block_device_mappings {
    device_name           = "/dev/sda1"
    volume_size           = 20
    volume_type           = "gp3"
    delete_on_termination = true
  }
}

build {
  name    = "billage-golden-ami"
  sources = ["source.amazon-ebs.ubuntu"]

  # 0. Create destination directory first
  provisioner "shell" {
    inline = ["mkdir -p /tmp/monitoring"]
  }

  # 1. Upload monitoring files
  provisioner "file" {
    source      = "files/monitoring/"
    destination = "/tmp/monitoring/"
  }

  # 2. Upload systemd service file
  provisioner "file" {
    source      = "files/systemd/monitoring.service"
    destination = "/tmp/monitoring.service"
  }

  # 3. Upload and run setup script
  provisioner "shell" {
    script = "scripts/setup.sh"
    environment_vars = [
      "LOKI_URL=${var.loki_url}"
    ]
    execute_command = "chmod +x {{ .Path }}; {{ .Vars }} sudo -E bash '{{ .Path }}'"
  }

  # 4. Run cleanup script
  provisioner "shell" {
    script          = "scripts/cleanup.sh"
    execute_command = "chmod +x {{ .Path }}; sudo bash '{{ .Path }}'"
  }

  post-processor "manifest" {
    output     = "manifest.json"
    strip_path = true
  }
}