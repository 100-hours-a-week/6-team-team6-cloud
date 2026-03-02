# rehearsal/infra/main.tf
# 목표: 기존 코드 영향 없이 리허설용 ALB + BE ASG + RDS를 한 번에 생성하는 최소 스택

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
      Component   = "rehearsal-simple-v2"
    }
  }
}

#==============================================================================
# 기존 네트워크 참조 (dev/prod 둘 중 하나를 바인딩)
#==============================================================================
data "aws_vpc" "base" {
  tags = {
    Name = "${var.project_name}-${var.base_vpc_env}-vpc"
  }
}

data "aws_subnet" "public_a" {
  tags = {
    Name = "${var.project_name}-${var.base_vpc_env}-public-subnet"
  }
}

data "aws_internet_gateway" "base" {
  filter {
    name   = "attachment.vpc-id"
    values = [data.aws_vpc.base.id]
  }
}

data "aws_caller_identity" "current" {}

#==============================================================================
# 퍼블릭 서브넷 2개를 만들되, 기존 ALB/ASG는 public-only로 단순화
#==============================================================================
resource "aws_subnet" "public_b" {
  vpc_id                  = data.aws_vpc.base.id
  cidr_block              = var.public_subnet_b_cidr
  availability_zone       = "${var.aws_region}${var.public_subnet_b_az}"
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.project_name}-${var.env}-rehearsal-public-${var.public_subnet_b_az}"
    Type = "public"
  }
}

resource "aws_route_table" "public_b" {
  vpc_id = data.aws_vpc.base.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = data.aws_internet_gateway.base.id
  }

  tags = {
    Name = "${var.project_name}-${var.env}-rehearsal-public-rt-${var.public_subnet_b_az}"
  }
}

resource "aws_route_table_association" "public_b" {
  subnet_id      = aws_subnet.public_b.id
  route_table_id = aws_route_table.public_b.id
}

#==============================================================================
# Security Groups
#==============================================================================
resource "aws_security_group" "alb" {
  name        = "${var.project_name}-${var.env}-rehearsal-alb-sg"
  description = "Security group for rehearsal ALB"
  vpc_id      = data.aws_vpc.base.id

  ingress {
    description = "HTTP for redirect(80 -> 8081)"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Rehearsal backend entry port"
    from_port   = 8081
    to_port     = 8081
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port = 0
    to_port   = 0
    protocol  = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-${var.env}-rehearsal-alb-sg"
  }
}

resource "aws_security_group" "backend" {
  name        = "${var.project_name}-${var.env}-rehearsal-be-sg"
  description = "Security group for rehearsal backend instances"
  vpc_id      = data.aws_vpc.base.id

  ingress {
    description = "From rehearsal ALB"
    from_port   = var.backend_container_port
    to_port     = var.backend_container_port
    protocol    = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  ingress {
    description = "SSH (temporary debug)"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.ssh_allowed_cidr
  }

  egress {
    from_port = 0
    to_port   = 0
    protocol  = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = "${var.project_name}-${var.env}-rehearsal-be-sg"
    Service = "backend"
  }
}

resource "aws_security_group" "rds" {
  name        = "${var.project_name}-${var.env}-rehearsal-rds-sg"
  description = "Security group for rehearsal RDS"
  vpc_id      = data.aws_vpc.base.id

  ingress {
    description = "MySQL from rehearsal backend"
    from_port   = 3306
    to_port     = 3306
    protocol    = "tcp"
    security_groups = [aws_security_group.backend.id]
  }

  egress {
    from_port = 0
    to_port   = 0
    protocol  = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-${var.env}-rehearsal-rds-sg"
  }
}

#==============================================================================
# IAM (EC2에서 ECR/SSM 사용)
#==============================================================================
resource "aws_iam_role" "app" {
  name = "${var.project_name}-${var.env}-rehearsal-app-role"

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
    Name = "${var.project_name}-${var.env}-rehearsal-app-role"
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
      Resource = "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/${var.project_name}/*"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "app_cloudwatch" {
  role       = aws_iam_role.app.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_iam_instance_profile" "app" {
  name = "${var.project_name}-${var.env}-rehearsal-app-profile"
  role = aws_iam_role.app.name
}

#==============================================================================
# ALB + TG + Listener (8081 그대로 사용)
#==============================================================================
resource "aws_lb" "rehearsal" {
  name               = "${var.project_name}-${var.env}-rehearsal-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = [data.aws_subnet.public_a.id, aws_subnet.public_b.id]

  tags = {
    Name = "${var.project_name}-${var.env}-rehearsal-alb"
  }
}

resource "aws_lb_target_group" "backend" {
  name        = "${var.project_name}-${var.env}-rehearsal-be-tg"
  port        = var.backend_container_port
  protocol    = "HTTP"
  vpc_id      = data.aws_vpc.base.id
  target_type = "instance"

  health_check {
    enabled             = true
    path                = var.backend_health_check_path
    protocol            = "HTTP"
    matcher             = "200"
    healthy_threshold   = 2
    unhealthy_threshold = 2
    timeout             = 5
    interval            = 30
  }

  tags = {
    Name    = "${var.project_name}-${var.env}-rehearsal-be-tg"
    Service = "backend"
  }
}

resource "aws_lb_listener" "http_80" {
  load_balancer_arn = aws_lb.rehearsal.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      port        = "8081"
      protocol    = "HTTP"
      status_code = "HTTP_301"
    }
  }
}

resource "aws_lb_listener" "http_8081" {
  load_balancer_arn = aws_lb.rehearsal.arn
  port              = 8081
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.backend.arn
  }
}

#==============================================================================
# ASG + Launch Template (backend만 단일 구성)
#==============================================================================
resource "aws_launch_template" "backend" {
  name_prefix   = "${var.project_name}-${var.env}-rehearsal-be-"
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
    ssm_path     = var.ssm_backend_path
    db_host      = aws_db_instance.main.address
    db_port      = aws_db_instance.main.port
    db_name      = aws_db_instance.main.db_name
    container_image = var.backend_container_image
    container_port  = var.backend_container_port
    service_name    = var.backend_service_name
  }))

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name    = "${var.project_name}-${var.env}-rehearsal-be"
      Service = "backend"
    }
  }
}

resource "aws_autoscaling_group" "backend" {
  name               = "${var.project_name}-${var.env}-rehearsal-be-asg"
  desired_capacity   = var.backend_asg_desired
  min_size           = var.backend_asg_min
  max_size           = var.backend_asg_max
  vpc_zone_identifier = [data.aws_subnet.public_a.id, aws_subnet.public_b.id]

  target_group_arns = [aws_lb_target_group.backend.arn]
  health_check_type         = "ELB"
  health_check_grace_period = 300

  launch_template {
    id      = aws_launch_template.backend.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "${var.project_name}-${var.env}-rehearsal-be"
    propagate_at_launch = true
  }

  tag {
    key                 = "Service"
    value               = "backend"
    propagate_at_launch = true
  }
}

#==============================================================================
# RDS (리허설용 단일 MySQL)
#==============================================================================
resource "aws_db_subnet_group" "rehearsal" {
  name        = "${var.project_name}-${var.env}-rehearsal-db-subnet-group"
  description = "Rehearsal DB subnet group"
  subnet_ids  = [data.aws_subnet.public_a.id, aws_subnet.public_b.id]

  tags = {
    Name = "${var.project_name}-${var.env}-rehearsal-db-subnet-group"
  }
}

resource "aws_db_parameter_group" "rehearsal" {
  name   = "${var.project_name}-${var.env}-rehearsal-mysql-params"
  family = "mysql8.0"

  parameter {
    name  = "character_set_server"
    value = "utf8mb4"
  }

  parameter {
    name  = "character_set_client"
    value = "utf8mb4"
  }

  parameter {
    name  = "collation_server"
    value = "utf8mb4_unicode_ci"
  }
}

resource "aws_db_instance" "main" {
  identifier = var.rds_identifier

  engine         = "mysql"
  engine_version = var.rds_engine_version
  instance_class = var.rds_instance_class
  port           = 3306
  db_name        = var.rds_db_name
  username       = var.rds_username
  password       = var.rds_password

  allocated_storage      = var.rds_allocated_storage
  max_allocated_storage  = var.rds_max_allocated_storage
  storage_type          = "gp3"
  storage_encrypted     = true
  db_subnet_group_name  = aws_db_subnet_group.rehearsal.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  parameter_group_name   = aws_db_parameter_group.rehearsal.name
  publicly_accessible    = var.rds_publicly_accessible
  multi_az              = var.rds_multi_az

  apply_immediately      = true
  backup_retention_period = var.rds_backup_retention_days
  skip_final_snapshot     = var.rds_skip_final_snapshot
  deletion_protection     = var.rds_deletion_protection

  tags = {
    Name = var.rds_identifier
  }

  depends_on = [aws_db_subnet_group.rehearsal]
}

#==============================================================================
# DNS (옵션): 기존 도메인에 리허설 레코드 등록
#==============================================================================
data "aws_route53_zone" "main" {
  count = var.create_dns_record ? 1 : 0
  name  = var.domain_name
}

resource "aws_route53_record" "rehearsal" {
  count = var.create_dns_record ? 1 : 0

  zone_id = data.aws_route53_zone.main[0].zone_id
  name    = "${var.dns_record_name}.${var.domain_name}"
  type    = "A"

  alias {
    name                   = aws_lb.rehearsal.dns_name
    zone_id                = aws_lb.rehearsal.zone_id
    evaluate_target_health = true
  }
}
