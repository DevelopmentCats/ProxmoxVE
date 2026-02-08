#!/usr/bin/env bash

# Copyright (c) 2021-2025 community-scripts ORG
# Author: DevelopmentCats
# License: MIT | https://github.com/community-scripts/ProxmoxVED/raw/main/LICENSE
# Source: https://git.chesher.xyz/cat/romm-proxmox-ve-script

source /dev/stdin <<< "$FUNCTIONS_FILE_PATH"

color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

msg_info "Installing Dependencies"
$STD apt-get install -y sudo curl openssl ca-certificates gnupg mc wget
msg_ok "Installed Dependencies"

msg_info "Installing Docker"
$STD install -m 0755 -d /etc/apt/keyrings

# Download and install Docker GPG key
$STD curl -fsSL https://download.docker.com/linux/debian/gpg -o /tmp/docker.gpg
$STD gpg --dearmor -o /etc/apt/keyrings/docker.gpg /tmp/docker.gpg
$STD chmod a+r /etc/apt/keyrings/docker.gpg
rm -f /tmp/docker.gpg

echo \
  "deb [arch="$(dpkg --print-architecture)" signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian \
  "$(. /etc/os-release && echo "$VERSION_CODENAME")" stable" | \
  tee /etc/apt/sources.list.d/docker.list > /dev/null

$STD apt-get update
$STD apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
msg_ok "Installed Docker"

msg_info "Creating Directories"
mkdir -p /opt/romm/library/{roms,bios}
mkdir -p /opt/romm/library/roms/{gbc,gba,ps,switch,n64,snes,nes,genesis}
mkdir -p /opt/romm/library/bios/{gba,ps,ps2}
mkdir -p /opt/romm/assets
mkdir -p /opt/romm/config
msg_ok "Created Directories"

msg_info "Generating Credentials"
AUTH_KEY=$(openssl rand -hex 32)
DB_ROOT_PASSWORD=$(openssl rand -hex 16)
DB_USER_PASSWORD=$(openssl rand -hex 16)
msg_ok "Generated Credentials"

msg_info "Creating Docker Compose File"
cat >/opt/romm/docker-compose.yml <<EOF
version: "3"
volumes:
  mysql_data:
  romm_resources:
  romm_redis_data:
services:
  romm:
    image: rommapp/romm:latest
    container_name: romm
    restart: unless-stopped
    environment:
      - DB_HOST=romm-db
      - DB_NAME=romm
      - DB_USER=romm-user
      - DB_PASSWD=${DB_USER_PASSWORD}
      - ROMM_AUTH_SECRET_KEY=${AUTH_KEY}
      # Background task defaults (can be modified in docker-compose.yml after install)
      - ENABLE_RESCAN_ON_FILESYSTEM_CHANGE=false
      - RESCAN_ON_FILESYSTEM_CHANGE_DELAY=5
      - ENABLE_SCHEDULED_RESCAN=false
      - SCHEDULED_RESCAN_CRON=0 3 * * *
      - ENABLE_SCHEDULED_UPDATE_SWITCH_TITLEDB=false
      - SCHEDULED_UPDATE_SWITCH_TITLEDB_CRON=0 4 * * *
    volumes:
      - romm_resources:/romm/resources
      - romm_redis_data:/redis-data
      - /opt/romm/library:/romm/library
      - /opt/romm/assets:/romm/assets
      - /opt/romm/config:/romm/config
    ports:
      - 8080:8080
    depends_on:
      romm-db:
        condition: service_healthy
        restart: true
  romm-db:
    image: mariadb:latest
    container_name: romm-db
    restart: unless-stopped
    environment:
      - MARIADB_ROOT_PASSWORD=${DB_ROOT_PASSWORD}
      - MARIADB_DATABASE=romm
      - MARIADB_USER=romm-user
      - MARIADB_PASSWORD=${DB_USER_PASSWORD}
    volumes:
      - mysql_data:/var/lib/mysql
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      start_period: 30s
      start_interval: 10s
      interval: 10s
      timeout: 5s
      retries: 5
EOF
msg_ok "Created Docker Compose File"

msg_info "Starting RomM"
cd /opt/romm
$STD docker compose up -d
msg_ok "Started RomM"

msg_info "Waiting for containers to be healthy"
for i in {1..60}; do
  if docker compose ps | grep -q "healthy"; then
    msg_ok "Containers are healthy"
    break
  fi
  sleep 2
  if [ $i -eq 60 ]; then
    msg_error "Containers failed to become healthy - check 'docker compose logs' in /opt/romm"
  fi
done

# Configure firewall if it exists
if command -v ufw >/dev/null 2>&1; then
  msg_info "Configuring Firewall"
  $STD ufw allow 8080/tcp
  msg_ok "Configured Firewall"
fi

msg_info "Saving credentials"
cat >/opt/romm/CREDENTIALS.txt <<EOF
==============================================
RomM Installation Credentials
==============================================
Database Root Password: ${DB_ROOT_PASSWORD}
Database User: romm-user
Database Password: ${DB_USER_PASSWORD}
Auth Secret Key: ${AUTH_KEY}

Location: /opt/romm
Docker Compose: /opt/romm/docker-compose.yml
Library: /opt/romm/library

To customize background tasks, edit:
/opt/romm/docker-compose.yml

Then restart: cd /opt/romm && docker compose restart
==============================================
EOF
chmod 600 /opt/romm/CREDENTIALS.txt
msg_ok "Saved credentials to /opt/romm/CREDENTIALS.txt"

motd_ssh
customize

msg_info "Cleaning up"
$STD apt-get -y autoremove
$STD apt-get -y autoclean
msg_ok "Cleaned"
