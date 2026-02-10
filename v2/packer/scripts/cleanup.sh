#!/bin/bash
set -euxo pipefail

echo "=========================================="
echo "Starting AMI Cleanup..."
echo "=========================================="

# Stop services that might be writing logs
systemctl stop rsyslog || true

echo "Cleaning apt cache..."
apt-get clean
apt-get autoremove -y
rm -rf /var/lib/apt/lists/*

echo "Cleaning temporary files..."
rm -rf /tmp/*
rm -rf /var/tmp/*

echo "Cleaning log files..."
# Truncate log files instead of deleting to preserve file permissions
find /var/log -type f -name "*.log" -exec truncate -s 0 {} \;
find /var/log -type f -name "*.gz" -delete
find /var/log -type f -name "*.old" -delete
find /var/log -type f -name "*.[0-9]" -delete

# Clean specific logs
truncate -s 0 /var/log/wtmp || true
truncate -s 0 /var/log/btmp || true
truncate -s 0 /var/log/lastlog || true
truncate -s 0 /var/log/auth.log || true
truncate -s 0 /var/log/syslog || true
truncate -s 0 /var/log/cloud-init.log || true
truncate -s 0 /var/log/cloud-init-output.log || true

# Clean journal logs
journalctl --rotate || true
journalctl --vacuum-time=1s || true

echo "Cleaning SSH keys and authorized_keys..."
rm -rf /home/ubuntu/.ssh/authorized_keys
rm -rf /root/.ssh/authorized_keys
# Remove host keys (will be regenerated on first boot)
rm -f /etc/ssh/ssh_host_*

echo "Cleaning shell history..."
# Clean ubuntu user history
rm -f /home/ubuntu/.bash_history
rm -f /home/ubuntu/.zsh_history
unset HISTFILE

# Clean root history
rm -f /root/.bash_history
rm -f /root/.zsh_history

echo "Cleaning cloud-init..."
# Reset cloud-init for fresh run on new instance
cloud-init clean --logs || true

echo "Cleaning machine-id..."
# Reset machine-id (will be regenerated on first boot)
truncate -s 0 /etc/machine-id || true
rm -f /var/lib/dbus/machine-id || true

echo "Syncing filesystem..."
sync

echo "=========================================="
echo "Cleanup Complete!"
echo "=========================================="