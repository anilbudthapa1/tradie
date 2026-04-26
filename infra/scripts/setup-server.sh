#!/usr/bin/env bash
# One-time VPS bootstrap for defecexinso.com (Debian/Ubuntu).
#
# Run as root (or with sudo) on a fresh server:
#   curl -fsSL https://raw.githubusercontent.com/YOU/REPO/main/infra/scripts/setup-server.sh | bash
# OR after cloning the repo:
#   sudo bash infra/scripts/setup-server.sh

set -euo pipefail

if [ "$EUID" -ne 0 ]; then
  echo "Run as root or with sudo." >&2
  exit 1
fi

echo "→ Updating apt + installing baseline packages…"
apt-get update -y
apt-get install -y --no-install-recommends \
  ca-certificates curl gnupg ufw fail2ban git \
  postgresql-client unattended-upgrades

echo "→ Enabling unattended security upgrades…"
dpkg-reconfigure -f noninteractive unattended-upgrades

echo "→ Configuring firewall…"
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp     comment 'ssh'
ufw allow 80/tcp     comment 'http'
ufw allow 443/tcp    comment 'https'
ufw allow 443/udp    comment 'http3'
ufw --force enable

echo "→ Hardening fail2ban defaults…"
systemctl enable --now fail2ban

if ! command -v docker >/dev/null; then
  echo "→ Installing Docker (official repo)…"
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg | \
    gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  . /etc/os-release
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/${ID} ${VERSION_CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
else
  echo "→ Docker already installed, skipping."
fi

echo "→ Creating deploy user (if missing)…"
if ! id -u deploy >/dev/null 2>&1; then
  useradd -m -s /bin/bash -G docker deploy
  mkdir -p /home/deploy/.ssh
  chmod 700 /home/deploy/.ssh
  if [ -f /root/.ssh/authorized_keys ]; then
    cp /root/.ssh/authorized_keys /home/deploy/.ssh/
    chmod 600 /home/deploy/.ssh/authorized_keys
    chown -R deploy:deploy /home/deploy/.ssh
  fi
fi

echo "✓ Server ready."
echo "  Next: as 'deploy', clone repo, drop in backend/.env.production,"
echo "        copy mobile/build/web → infra/web, then run infra/scripts/deploy.sh"
