# v2/envs/prod/main.tf
# Billage v2 Prod 환경 - ASG + ALB + RDS 아키텍처

terraform {
  required_version = ">= 1.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.env
      ManagedBy   = "terraform"
      Version     = "v2"
    }
  }
}

#==============================================================================
# Data Sources - 기존 v1 VPC 참조
#==============================================================================
data "aws_vpc" "existing" {
  tags = {
    Name = "${var.project_name}-${var.env}-vpc"
  }
}

data "aws_subnet" "public" {
  tags = {
    Name = "${var.project_name}-${var.env}-public-subnet"
  }
}

data "aws_route53_zone" "main" {
  name = var.domain_name
}

data "aws_caller_identity" "current" {}

# Private Subnets (RDS용)은 shared/rds/prod에서 생성

#==============================================================================
# Private Subnets (EC2용) - VPN NAT 경유 인터넷 접근
#==============================================================================
resource "aws_subnet" "private_a" {
  vpc_id                  = data.aws_vpc.existing.id
  cidr_block              = var.private_subnet_cidr_a
  availability_zone       = "${var.aws_region}a"
  map_public_ip_on_launch = false

  tags = {
    Name = "${var.project_name}-${var.env}-v2-private-subnet-a"
    Type = "private"
  }
}

resource "aws_subnet" "private_c" {
  vpc_id                  = data.aws_vpc.existing.id
  cidr_block              = var.private_subnet_cidr_c
  availability_zone       = "${var.aws_region}c"
  map_public_ip_on_launch = false

  tags = {
    Name = "${var.project_name}-${var.env}-v2-private-subnet-c"
    Type = "private"
  }
}

# VPC Peering 참조 (Management VPC와의 Peering)
data "aws_vpc_peering_connection" "management" {
  filter {
    name   = "accepter-vpc-info.vpc-id"
    values = [data.aws_vpc.existing.id]
  }

  filter {
    name   = "status-code"
    values = ["active"]
  }
}

# NAT Instance (Private Subnet 인터넷 접근용)
data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_security_group" "nat" {
  name        = "${var.project_name}-${var.env}-v2-nat-sg"
  description = "Security group for NAT instance"
  vpc_id      = data.aws_vpc.existing.id

  ingress {
    description = "All from Private Subnets"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.private_subnet_cidr_a, var.private_subnet_cidr_c]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-${var.env}-v2-nat-sg"
  }
}

resource "aws_instance" "nat" {
  ami                    = data.aws_ami.amazon_linux.id
  instance_type          = "t3.nano" # ~$3.80/월
  subnet_id              = data.aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.nat.id]
  source_dest_check      = false # NAT Instance 필수
  key_name               = var.key_name

  user_data = <<-USERDATA
    #!/bin/bash
    set -e
    # IP forwarding 활성화
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    sysctl -w net.ipv4.ip_forward=1

    # iptables NAT 설정
    PUB_IF=$(ip route | grep default | awk '{print $5}')
    iptables -t nat -A POSTROUTING -o $PUB_IF -s ${var.private_subnet_cidr_a} -j MASQUERADE
    iptables -t nat -A POSTROUTING -o $PUB_IF -s ${var.private_subnet_cidr_c} -j MASQUERADE
    iptables -A FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    iptables -A FORWARD -s ${var.private_subnet_cidr_a} -o $PUB_IF -j ACCEPT
    iptables -A FORWARD -s ${var.private_subnet_cidr_c} -o $PUB_IF -j ACCEPT

    # iptables 영구 저장
    yum install -y iptables-services 2>/dev/null || true
    iptables-save > /etc/sysconfig/iptables 2>/dev/null || true
    systemctl enable iptables 2>/dev/null || true
  USERDATA

  tags = {
    Name = "${var.project_name}-${var.env}-v2-nat-instance"
  }
}

# Private Route Table - 0.0.0.0/0 → NAT Instance
resource "aws_route_table" "private" {
  vpc_id = data.aws_vpc.existing.id

  route {
    cidr_block           = "0.0.0.0/0"
    network_interface_id = aws_instance.nat.primary_network_interface_id
  }

  route {
    cidr_block                = var.management_vpc_cidr
    vpc_peering_connection_id = data.aws_vpc_peering_connection.management.id
  }

  tags = {
    Name = "${var.project_name}-${var.env}-v2-private-rt"
  }
}

resource "aws_route_table_association" "private_a" {
  subnet_id      = aws_subnet.private_a.id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "private_c" {
  subnet_id      = aws_subnet.private_c.id
  route_table_id = aws_route_table.private.id
}

# Public Subnet 추가 (ALB용 - 2 AZ 필요)
resource "aws_subnet" "public_c" {
  vpc_id                  = data.aws_vpc.existing.id
  cidr_block              = var.public_subnet_cidr_c
  availability_zone       = "${var.aws_region}c"
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.project_name}-${var.env}-v2-public-subnet-c"
    Type = "public"
  }
}

# Public Subnet C의 Route Table 연결
data "aws_internet_gateway" "existing" {
  filter {
    name   = "attachment.vpc-id"
    values = [data.aws_vpc.existing.id]
  }
}

resource "aws_route_table" "public_c" {
  vpc_id = data.aws_vpc.existing.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = data.aws_internet_gateway.existing.id
  }

  tags = {
    Name = "${var.project_name}-${var.env}-v2-public-rt-c"
  }
}

resource "aws_route_table_association" "public_c" {
  subnet_id      = aws_subnet.public_c.id
  route_table_id = aws_route_table.public_c.id
}

# Private Route Table (RDS용)은 shared/rds/prod에서 별도 생성
# Private Route Table (EC2용)은 위에서 생성 - NAT Instance 경유 인터넷 접근

#==============================================================================
# Security Groups
#==============================================================================
# ALB Security Group
resource "aws_security_group" "alb" {
  name        = "${var.project_name}-${var.env}-v2-alb-sg"
  description = "Security group for ALB"
  vpc_id      = data.aws_vpc.existing.id

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-${var.env}-v2-alb-sg"
  }
}

# Backend Security Group
resource "aws_security_group" "backend" {
  name        = "${var.project_name}-${var.env}-v2-be-sg"
  description = "Security group for backend instances"
  vpc_id      = data.aws_vpc.existing.id

  ingress {
    description     = "From ALB"
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  ingress {
    description = "SSH from VPN (Masquerade: Management VPC CIDR)"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.vpn_cidr
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = "${var.project_name}-${var.env}-v2-be-sg"
    Service = "backend"
  }
}

# Frontend Security Group
resource "aws_security_group" "frontend" {
  name        = "${var.project_name}-${var.env}-v2-fe-sg"
  description = "Security group for frontend instances"
  vpc_id      = data.aws_vpc.existing.id

  ingress {
    description     = "From ALB"
    from_port       = 3000
    to_port         = 3000
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  ingress {
    description = "SSH from VPN (Masquerade: Management VPC CIDR)"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.vpn_cidr
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = "${var.project_name}-${var.env}-v2-fe-sg"
    Service = "frontend"
  }
}

# AI Security Group
resource "aws_security_group" "ai" {
  name        = "${var.project_name}-${var.env}-v2-ai-sg"
  description = "Security group for AI instances"
  vpc_id      = data.aws_vpc.existing.id

  ingress {
    description     = "From ALB"
    from_port       = 5000
    to_port         = 5000
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  ingress {
    description = "SSH from VPN (Masquerade: Management VPC CIDR)"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.vpn_cidr
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = "${var.project_name}-${var.env}-v2-ai-sg"
    Service = "ai"
  }
}

#==============================================================================
# RDS 참조 (shared에서 생성)
#==============================================================================
data "aws_db_instance" "main" {
  db_instance_identifier = "${var.project_name}-${var.env}-v2-mysql"
}

#==============================================================================
# ALB (Application Load Balancer)
#==============================================================================
resource "aws_lb" "main" {
  name               = "${var.project_name}-${var.env}-v2-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = [data.aws_subnet.public.id, aws_subnet.public_c.id]
  idle_timeout       = 300 # WebSocket 연결 안정성을 위해 기본(60s)보다 확장

  enable_deletion_protection = false

  tags = {
    Name = "${var.project_name}-${var.env}-v2-alb"
  }
}

# Target Groups
resource "aws_lb_target_group" "backend" {
  name     = "${var.project_name}-${var.env}-v2-be-tg"
  port     = 8080
  protocol = "HTTP"
  vpc_id   = data.aws_vpc.existing.id

  health_check {
    enabled             = true
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
    path                = var.backend_health_check_path
    matcher             = "200"
  }

  tags = {
    Name    = "${var.project_name}-${var.env}-v2-be-tg"
    Service = "backend"
  }
}

resource "aws_lb_target_group" "frontend" {
  name     = "${var.project_name}-${var.env}-v2-fe-tg"
  port     = 3000
  protocol = "HTTP"
  vpc_id   = data.aws_vpc.existing.id

  health_check {
    enabled             = true
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
    path                = "/"
    matcher             = "200-399"
  }

  tags = {
    Name    = "${var.project_name}-${var.env}-v2-fe-tg"
    Service = "frontend"
  }
}

resource "aws_lb_target_group" "ai" {
  name     = "${var.project_name}-${var.env}-v2-ai-tg"
  port     = 5000
  protocol = "HTTP"
  vpc_id   = data.aws_vpc.existing.id

  health_check {
    enabled             = true
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
    path                = var.ai_health_check_path
    matcher             = "200"
  }

  tags = {
    Name    = "${var.project_name}-${var.env}-v2-ai-tg"
    Service = "ai"
  }
}

# ALB Listeners
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

# ACM 인증서 참조 (shared/acm에서 생성)
data "aws_acm_certificate" "main" {
  domain      = "*.${var.domain_name}"
  statuses    = ["ISSUED"]
  most_recent = true
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.main.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = data.aws_acm_certificate.main.arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.frontend.arn
  }
}

# Path based routing
resource "aws_lb_listener_rule" "ws" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 90

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.backend.arn
  }

  condition {
    path_pattern {
      values = ["/ws/*"]
    }
  }
}

resource "aws_lb_listener_rule" "api" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 100

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.backend.arn
  }

  condition {
    host_header {
      values = ["prod-api-v2.${var.domain_name}"]
    }
  }
}

resource "aws_lb_listener_rule" "ai" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 200

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.ai.arn
  }

  condition {
    path_pattern {
      values = ["/ai/*"]
    }
  }
}

#==============================================================================
# IAM Role for EC2
#==============================================================================
resource "aws_iam_role" "app" {
  name = "${var.project_name}-${var.env}-v2-app-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
  })

  tags = {
    Name = "${var.project_name}-${var.env}-v2-app-role"
  }
}

resource "aws_iam_role_policy" "app_ecr" {
  name = "ecr-pull"
  role = aws_iam_role.app.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage"
        ]
        Resource = "arn:aws:ecr:${var.aws_region}:${data.aws_caller_identity.current.account_id}:repository/${var.project_name}-*"
      }
    ]
  })
}

resource "aws_iam_role_policy" "app_ssm" {
  name = "ssm-read"
  role = aws_iam_role.app.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "ssm:GetParameter",
        "ssm:GetParameters",
        "ssm:GetParametersByPath"
      ]
      Resource = "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/${var.project_name}/${var.env}/*"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "app_cloudwatch" {
  role       = aws_iam_role.app.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_iam_instance_profile" "app" {
  name = "${var.project_name}-${var.env}-v2-app-profile"
  role = aws_iam_role.app.name
}

#==============================================================================
# Launch Templates (서비스별 분리)
#==============================================================================
# Backend Launch Template
resource "aws_launch_template" "backend" {
  name          = "${var.project_name}-${var.env}-v2-be-lt"
  description   = "Launch template for backend instances"
  image_id      = var.golden_ami_id
  instance_type = var.backend_instance_type
  key_name      = var.key_name

  vpc_security_group_ids = [aws_security_group.backend.id]

  iam_instance_profile {
    name = aws_iam_instance_profile.app.name
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = var.app_root_volume_size
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  user_data = base64encode(templatefile("${path.module}/user_data_backend.sh.tpl", {
    env          = var.env
    project_name = var.project_name
    aws_region   = var.aws_region
    ecr_registry = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com"
  }))

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name    = "${var.project_name}-${var.env}-v2-be"
      Service = "backend"
    }
  }

  tags = {
    Name    = "${var.project_name}-${var.env}-v2-be-lt"
    Service = "backend"
  }
}

# Frontend Launch Template
resource "aws_launch_template" "frontend" {
  name          = "${var.project_name}-${var.env}-v2-fe-lt"
  description   = "Launch template for frontend instances"
  image_id      = var.golden_ami_id
  instance_type = var.frontend_instance_type
  key_name      = var.key_name

  vpc_security_group_ids = [aws_security_group.frontend.id]

  iam_instance_profile {
    name = aws_iam_instance_profile.app.name
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = var.app_root_volume_size
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  user_data = base64encode(templatefile("${path.module}/user_data_frontend.sh.tpl", {
    env          = var.env
    project_name = var.project_name
    aws_region   = var.aws_region
    ecr_registry = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com"
  }))

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name    = "${var.project_name}-${var.env}-v2-fe"
      Service = "frontend"
    }
  }

  tags = {
    Name    = "${var.project_name}-${var.env}-v2-fe-lt"
    Service = "frontend"
  }
}

# AI Launch Template
resource "aws_launch_template" "ai" {
  name          = "${var.project_name}-${var.env}-v2-ai-lt"
  description   = "Launch template for AI instances"
  image_id      = var.golden_ami_id
  instance_type = var.ai_instance_type
  key_name      = var.key_name

  vpc_security_group_ids = [aws_security_group.ai.id]

  iam_instance_profile {
    name = aws_iam_instance_profile.app.name
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = var.app_root_volume_size
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  user_data = base64encode(templatefile("${path.module}/user_data_ai.sh.tpl", {
    env          = var.env
    project_name = var.project_name
    aws_region   = var.aws_region
    ecr_registry = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com"
  }))

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name    = "${var.project_name}-${var.env}-v2-ai"
      Service = "ai"
    }
  }

  tags = {
    Name    = "${var.project_name}-${var.env}-v2-ai-lt"
    Service = "ai"
  }
}

#==============================================================================
# Auto Scaling Groups (서비스별 분리)
#==============================================================================
# Backend ASG
resource "aws_autoscaling_group" "backend" {
  name                = "${var.project_name}-${var.env}-v2-be-asg"
  desired_capacity    = var.backend_asg_desired
  min_size            = var.backend_asg_min
  max_size            = var.backend_asg_max
  vpc_zone_identifier = [aws_subnet.private_a.id, aws_subnet.private_c.id]
  target_group_arns   = [aws_lb_target_group.backend.arn]

  health_check_type         = "ELB"
  health_check_grace_period = 300

  launch_template {
    id      = aws_launch_template.backend.id
    version = "$Latest"
  }

  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 50
    }
  }

  tag {
    key                 = "Name"
    value               = "${var.project_name}-${var.env}-v2-be"
    propagate_at_launch = true
  }

  tag {
    key                 = "Service"
    value               = "backend"
    propagate_at_launch = true
  }
}

# Frontend ASG
resource "aws_autoscaling_group" "frontend" {
  name                = "${var.project_name}-${var.env}-v2-fe-asg"
  desired_capacity    = var.frontend_asg_desired
  min_size            = var.frontend_asg_min
  max_size            = var.frontend_asg_max
  vpc_zone_identifier = [aws_subnet.private_a.id, aws_subnet.private_c.id]
  target_group_arns   = [aws_lb_target_group.frontend.arn]

  health_check_type         = "ELB"
  health_check_grace_period = 300

  launch_template {
    id      = aws_launch_template.frontend.id
    version = "$Latest"
  }

  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 50
    }
  }

  tag {
    key                 = "Name"
    value               = "${var.project_name}-${var.env}-v2-fe"
    propagate_at_launch = true
  }

  tag {
    key                 = "Service"
    value               = "frontend"
    propagate_at_launch = true
  }
}

# AI ASG
resource "aws_autoscaling_group" "ai" {
  name                = "${var.project_name}-${var.env}-v2-ai-asg"
  desired_capacity    = var.ai_asg_desired
  min_size            = var.ai_asg_min
  max_size            = var.ai_asg_max
  vpc_zone_identifier = [aws_subnet.private_a.id, aws_subnet.private_c.id]
  target_group_arns   = [aws_lb_target_group.ai.arn]

  health_check_type         = "ELB"
  health_check_grace_period = 300

  launch_template {
    id      = aws_launch_template.ai.id
    version = "$Latest"
  }

  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 50
    }
  }

  tag {
    key                 = "Name"
    value               = "${var.project_name}-${var.env}-v2-ai"
    propagate_at_launch = true
  }

  tag {
    key                 = "Service"
    value               = "ai"
    propagate_at_launch = true
  }
}

#==============================================================================
# Route 53
#==============================================================================
resource "aws_route53_record" "v2" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = "v2.${var.domain_name}"
  type    = "A"

  alias {
    name                   = aws_lb.main.dns_name
    zone_id                = aws_lb.main.zone_id
    evaluate_target_health = true
  }
}

resource "aws_route53_record" "api_v2" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = "prod-api-v2.${var.domain_name}"
  type    = "A"

  alias {
    name                   = aws_lb.main.dns_name
    zone_id                = aws_lb.main.zone_id
    evaluate_target_health = true
  }
}
