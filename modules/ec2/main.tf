# modules/ec2/main.tf
# EC2 인스턴스 정의

# Ubuntu 24.04 LTS ARM64 AMI 조회
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]  # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-arm64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "architecture"
    values = ["arm64"]
  }
}

# Key Pair (기존 키 사용 또는 새로 생성)
resource "aws_key_pair" "main" {
  count      = var.create_key_pair ? 1 : 0
  key_name   = "${var.project_name}-${var.env}-keypair"
  public_key = var.public_key

  tags = {
    Name        = "${var.project_name}-${var.env}-keypair"
    Environment = var.env
    Project     = var.project_name
  }
}

# EC2 Instance
resource "aws_instance" "main" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.instance_type
  key_name                    = var.create_key_pair ? aws_key_pair.main[0].key_name : var.existing_key_name
  subnet_id                   = var.subnet_id
  vpc_security_group_ids      = var.security_group_ids
  associate_public_ip_address = true
  iam_instance_profile        = var.iam_instance_profile != "" ? var.iam_instance_profile : null

  # 환경 설정 스크립트 (첫 부팅 시 실행)
  user_data = var.user_data != "" ? var.user_data : null

  root_block_device {
    volume_size           = var.root_volume_size
    volume_type           = "gp3"
    delete_on_termination = true
    encrypted             = true

    tags = {
      Name        = "${var.project_name}-${var.env}-root-volume"
      Environment = var.env
      Project     = var.project_name
    }
  }

  # 인스턴스 메타데이터 서비스 v2 (보안 강화)
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"  # IMDSv2 강제
    http_put_response_hop_limit = 1
  }

  # 인스턴스 종료 방지 (운영 환경에서 활성화)
  disable_api_termination = var.env == "prod" ? true : false

  tags = merge(
    {
      Name        = "${var.project_name}-${var.env}-${var.instance_name}"
      Environment = var.env
      Project     = var.project_name
      Role        = var.instance_role
    },
    var.additional_tags
  )

  # Credit Specification for T-series (burstable)
  credit_specification {
    cpu_credits = "standard"  # standard: 크레딧 소진 시 기본 성능, unlimited: 추가 비용 발생
  }

  lifecycle {
    ignore_changes = [ami]  # AMI 업데이트로 인한 재생성 방지
  }
}

# Elastic IP (선택적)
resource "aws_eip" "main" {
  count    = var.create_eip ? 1 : 0
  instance = aws_instance.main.id
  domain   = "vpc"

  tags = {
    Name        = "${var.project_name}-${var.env}-eip"
    Environment = var.env
    Project     = var.project_name
  }

  depends_on = [aws_instance.main]
}
