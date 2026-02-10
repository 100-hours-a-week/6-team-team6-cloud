#!/bin/bash
set -euxo pipefail

echo "=========================================="
echo "Starting Golden AMI Setup..."
echo "=========================================="

# Update package lists only (no upgrade to avoid dependency conflicts)
apt-get update

# Install required dependencies
# Note: jq removed - causes dependency issues and not used in this setup
apt-get install -y \
    apt-transport-https \
    ca-certificates \
    curl \
    gnupg \
    lsb-release \
    unzip

echo "=========================================="
echo "Installing Docker Engine..."
echo "=========================================="

# Add Docker's official GPG key
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --batch --yes --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

# Set up Docker repository
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

# Install Docker Engine and Docker Compose Plugin
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Add ubuntu user to docker group
usermod -aG docker ubuntu

# Enable and start Docker
systemctl enable docker
systemctl start docker

echo "=========================================="
echo "Installing AWS CLI v2..."
echo "=========================================="

# Download and install AWS CLI v2
curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "/tmp/awscliv2.zip"
unzip -q /tmp/awscliv2.zip -d /tmp
/tmp/aws/install
rm -rf /tmp/aws /tmp/awscliv2.zip

# Verify installation
aws --version

echo "=========================================="
echo "Configuring Amazon SSM Agent..."
echo "=========================================="

# SSM Agent is pre-installed on Ubuntu 22.04 AMIs via snap
# Just ensure it's enabled
systemctl enable snap.amazon-ssm-agent.amazon-ssm-agent.service || true

echo "=========================================="
echo "Installing Amazon ECR Credential Helper..."
echo "=========================================="

apt-get install -y amazon-ecr-credential-helper

# Configure Docker to use ECR credential helper for ubuntu user
mkdir -p /home/ubuntu/.docker
cat > /home/ubuntu/.docker/config.json <<'EOF'
{
    "credsStore": "ecr-login"
}
EOF
chown -R ubuntu:ubuntu /home/ubuntu/.docker

# Also configure for root user
mkdir -p /root/.docker
cat > /root/.docker/config.json <<'EOF'
{
    "credsStore": "ecr-login"
}
EOF

echo "=========================================="
echo "Setting up Monitoring Stack..."
echo "=========================================="

# Create monitoring directory
mkdir -p /opt/monitoring
cp -r /tmp/monitoring/* /opt/monitoring/

# Update Loki URL in promtail config if provided
if [ -n "${LOKI_URL:-}" ]; then
    sed -i "s|http://loki:3100/loki/api/v1/push|${LOKI_URL}|g" /opt/monitoring/promtail-config.yaml
fi

# Set proper permissions
chmod 644 /opt/monitoring/docker-compose.yml
chmod 644 /opt/monitoring/promtail-config.yaml

echo "=========================================="
echo "Creating Application Log Directory..."
echo "=========================================="

# Create log directory with proper permissions
mkdir -p /var/log/app
chmod 755 /var/log/app
chown ubuntu:ubuntu /var/log/app

echo "=========================================="
echo "Setting up Systemd Service..."
echo "=========================================="

# Copy systemd service file
cp /tmp/monitoring.service /etc/systemd/system/monitoring.service
chmod 644 /etc/systemd/system/monitoring.service

# Reload systemd and enable service
systemctl daemon-reload
systemctl enable monitoring.service

echo "=========================================="
echo "Pulling Docker Images..."
echo "=========================================="

# Pre-pull monitoring images to reduce first boot time
docker pull prom/node-exporter:latest || true
docker pull gcr.io/cadvisor/cadvisor:latest || true
docker pull grafana/promtail:latest || true

echo "=========================================="
echo "Setup Complete!"
echo "=========================================="