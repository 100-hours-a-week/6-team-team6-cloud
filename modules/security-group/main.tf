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

  # Spring Boot Backend
  ingress {
    description = "Spring Boot"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Next.js Frontend
  ingress {
    description = "Next.js"
    from_port   = 3000
    to_port     = 3000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # FastAPI AI Server
  ingress {
    description = "FastAPI"
    from_port   = 5000
    to_port     = 5000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
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
  }

  # cAdvisor - 모니터링 서버에서만 접근
  ingress {
    description     = "cAdvisor"
    from_port       = 8082
    to_port         = 8082
    protocol        = "tcp"
    security_groups = [aws_security_group.monitoring.id]
  }

  # MySQL Exporter - 모니터링 서버에서만 접근
  ingress {
    description     = "MySQL Exporter"
    from_port       = 9104
    to_port         = 9104
    protocol        = "tcp"
    security_groups = [aws_security_group.monitoring.id]
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
