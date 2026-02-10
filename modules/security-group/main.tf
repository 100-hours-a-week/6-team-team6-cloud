# modules/security-group/main.tf
# Security Group 정의

# Main Server Security Group
resource "aws_security_group" "main" {
  name        = "${var.project_name}-${var.env}-main-sg"
  description = "Security group for main server"
  vpc_id      = var.vpc_id

  # SSH - 관리용 (필요시 특정 IP로 제한 권장)
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.ssh_allowed_cidr
  }

  # SSH - DevOps VPN (항상 허용 - DevOps는 모든 인스턴스 접근 권한)
  ingress {
    description = "SSH from DevOps VPN"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.vpn_devops_cidr]
  }

  # HTTP
  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # HTTPS
  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # MySQL - VPC 내부에서만 접근 (개발 단계에서는 외부 허용)
  ingress {
    description = "MySQL"
    from_port   = 3306
    to_port     = 3306
    protocol    = "tcp"
    cidr_blocks = var.db_allowed_cidr
  }

  # Spring Boot Backend - VPN에서만 접근 (Nginx 리버스 프록시 경유)
  # 0.0.0.0/0 제거됨 - VPN role-based access로 대체

  # Next.js Frontend - VPN에서만 접근 (Nginx 리버스 프록시 경유)
  # 0.0.0.0/0 제거됨 - VPN role-based access로 대체

  # FastAPI AI Server - VPN에서만 접근 (Nginx 리버스 프록시 경유)
  # 0.0.0.0/0 제거됨 - VPN role-based access로 대체

  # Outbound - 모든 트래픽 허용
  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  #============================================================================
  # VPN 역할별 접근 제어 (Pure Routing용)
  # DevOps:   10.100.0.16/28 - SSH, 전체 서비스
  # Backend:  10.100.0.32/28 - SSH, MySQL, Spring Boot
  # Frontend: 10.100.0.48/28 - Web Port (80, 443, 3000)
  # AI/ML:    10.100.0.64/28 - FastAPI (5000)
  #============================================================================

  # DevOps VPN - SSH 접근
  dynamic "ingress" {
    for_each = var.enable_vpn_role_based_access ? [1] : []
    content {
      description = "SSH from DevOps VPN"
      from_port   = 22
      to_port     = 22
      protocol    = "tcp"
      cidr_blocks = [var.vpn_devops_cidr]
    }
  }

  # DevOps VPN - 전체 서비스 접근 (MySQL, Spring Boot, FastAPI)
  dynamic "ingress" {
    for_each = var.enable_vpn_role_based_access ? [1] : []
    content {
      description = "All services from DevOps VPN"
      from_port   = 0
      to_port     = 65535
      protocol    = "tcp"
      cidr_blocks = [var.vpn_devops_cidr]
    }
  }

  # Backend VPN - SSH 접근
  dynamic "ingress" {
    for_each = var.enable_vpn_role_based_access ? [1] : []
    content {
      description = "SSH from Backend VPN"
      from_port   = 22
      to_port     = 22
      protocol    = "tcp"
      cidr_blocks = [var.vpn_backend_cidr]
    }
  }

  # Backend VPN - MySQL 접근
  dynamic "ingress" {
    for_each = var.enable_vpn_role_based_access ? [1] : []
    content {
      description = "MySQL from Backend VPN"
      from_port   = 3306
      to_port     = 3306
      protocol    = "tcp"
      cidr_blocks = [var.vpn_backend_cidr]
    }
  }

  # Backend VPN - Spring Boot 접근
  dynamic "ingress" {
    for_each = var.enable_vpn_role_based_access ? [1] : []
    content {
      description = "Spring Boot from Backend VPN"
      from_port   = 8080
      to_port     = 8080
      protocol    = "tcp"
      cidr_blocks = [var.vpn_backend_cidr]
    }
  }

  # Frontend VPN - HTTP 접근
  dynamic "ingress" {
    for_each = var.enable_vpn_role_based_access ? [1] : []
    content {
      description = "HTTP from Frontend VPN"
      from_port   = 80
      to_port     = 80
      protocol    = "tcp"
      cidr_blocks = [var.vpn_frontend_cidr]
    }
  }

  # Frontend VPN - HTTPS 접근
  dynamic "ingress" {
    for_each = var.enable_vpn_role_based_access ? [1] : []
    content {
      description = "HTTPS from Frontend VPN"
      from_port   = 443
      to_port     = 443
      protocol    = "tcp"
      cidr_blocks = [var.vpn_frontend_cidr]
    }
  }

  # Frontend VPN - Next.js 접근
  dynamic "ingress" {
    for_each = var.enable_vpn_role_based_access ? [1] : []
    content {
      description = "Next.js from Frontend VPN"
      from_port   = 3000
      to_port     = 3000
      protocol    = "tcp"
      cidr_blocks = [var.vpn_frontend_cidr]
    }
  }

  # AI/ML VPN - FastAPI 접근
  dynamic "ingress" {
    for_each = var.enable_vpn_role_based_access ? [1] : []
    content {
      description = "FastAPI from AI/ML VPN"
      from_port   = 5000
      to_port     = 5000
      protocol    = "tcp"
      cidr_blocks = [var.vpn_ai_ml_cidr]
    }
  }

  tags = {
    Name        = "${var.project_name}-${var.env}-main-sg"
    Environment = var.env
    Project     = var.project_name
  }

  lifecycle {
    create_before_destroy = true
  }
}

#==============================================================================
# Monitoring Server Security Group
#==============================================================================
resource "aws_security_group" "monitoring" {
  name        = "${var.project_name}-${var.env}-monitoring-sg"
  description = "Security group for monitoring server (Prometheus, Grafana, Loki)"
  vpc_id      = var.vpc_id

  # SSH - 관리용
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.ssh_allowed_cidr
  }

  # SSH - DevOps VPN (항상 허용 - DevOps는 모든 인스턴스 접근 권한)
  ingress {
    description = "SSH from DevOps VPN"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.vpn_devops_cidr]
  }

  # Grafana - 관리자 접근
  ingress {
    description = "Grafana"
    from_port   = 3000
    to_port     = 3000
    protocol    = "tcp"
    cidr_blocks = var.monitoring_allowed_cidr
  }

  # Prometheus - 관리자 접근
  ingress {
    description = "Prometheus"
    from_port   = 9090
    to_port     = 9090
    protocol    = "tcp"
    cidr_blocks = var.monitoring_allowed_cidr
  }

  # Loki - 타겟 서버에서 로그 전송
  ingress {
    description = "Loki"
    from_port   = 3100
    to_port     = 3100
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  #============================================================================
  # DevOps VPN - 모니터링 서버 전체 접근 (SSH, Grafana, Prometheus, Loki)
  #============================================================================
  dynamic "ingress" {
    for_each = var.enable_vpn_role_based_access ? [1] : []
    content {
      description = "All access from DevOps VPN"
      from_port   = 0
      to_port     = 65535
      protocol    = "tcp"
      cidr_blocks = [var.vpn_devops_cidr]
    }
  }

  # Outbound - 모든 트래픽 허용
  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "${var.project_name}-${var.env}-monitoring-sg"
    Environment = var.env
    Project     = var.project_name
  }

  lifecycle {
    create_before_destroy = true
  }
}

#==============================================================================
# Monitoring Target Security Group
#==============================================================================
resource "aws_security_group" "monitoring_target" {
  name        = "${var.project_name}-${var.env}-monitoring-target-sg"
  description = "Security group for monitoring target servers (Exporters)"
  vpc_id      = var.vpc_id

  # Node Exporter - 모니터링 서버에서만 접근
  ingress {
    description     = "Node Exporter"
    from_port       = 9100
    to_port         = 9100
    protocol        = "tcp"
    security_groups = [aws_security_group.monitoring.id]
    cidr_blocks     = var.management_scrape_cidr
  }

  # cAdvisor - 모니터링 서버에서만 접근
  ingress {
    description     = "cAdvisor"
    from_port       = 8082
    to_port         = 8082
    protocol        = "tcp"
    security_groups = [aws_security_group.monitoring.id]
    cidr_blocks     = var.management_scrape_cidr
  }

  # MySQL Exporter - 모니터링 서버에서만 접근
  ingress {
    description     = "MySQL Exporter"
    from_port       = 9104
    to_port         = 9104
    protocol        = "tcp"
    security_groups = [aws_security_group.monitoring.id]
    cidr_blocks     = var.management_scrape_cidr
  }

  #============================================================================
  # DevOps VPN - Exporter 접근 (Node Exporter, cAdvisor, MySQL Exporter)
  #============================================================================
  dynamic "ingress" {
    for_each = var.enable_vpn_role_based_access ? [1] : []
    content {
      description = "Exporters from DevOps VPN"
      from_port   = 9100
      to_port     = 9104
      protocol    = "tcp"
      cidr_blocks = [var.vpn_devops_cidr]
    }
  }

  dynamic "ingress" {
    for_each = var.enable_vpn_role_based_access ? [1] : []
    content {
      description = "cAdvisor from DevOps VPN"
      from_port   = 8082
      to_port     = 8082
      protocol    = "tcp"
      cidr_blocks = [var.vpn_devops_cidr]
    }
  }

  # Outbound - 모든 트래픽 허용
  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "${var.project_name}-${var.env}-monitoring-target-sg"
    Environment = var.env
    Project     = var.project_name
  }

  lifecycle {
    create_before_destroy = true
  }

  depends_on = [aws_security_group.monitoring]
}
