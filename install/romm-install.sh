#!/usr/bin/env bash

# Copyright (c) 2021-2026 community-scripts ORG
# Author: DevelopmentCats
# Sponsor: https://ko-fi.com/developmentcats
# License: MIT | https://github.com/DevelopmentCats/ProxmoxVE/raw/branch/main/LICENSE
# Source: https://github.com/rommapp/romm

source /dev/stdin <<< "$FUNCTIONS_FILE_PATH"

color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

APP="RomM"
ROMM_DIR="/opt/romm"
ROMM_BASE="/romm"
ROMM_CREDS="/root/romm.creds"

msg_info "Installing Dependencies"
$STD apt-get install -y \
  git \
  curl \
  build-essential \
  mariadb-server \
  redis-server \
  libmariadb-dev \
  libpq-dev \
  libmagic-dev \
  openssl
msg_ok "Installed Dependencies"

msg_info "Setting up MariaDB"
setup_mariadb
MARIADB_DB_NAME="romm" MARIADB_DB_USER="romm" MARIADB_DB_CREDS_FILE="$ROMM_CREDS" setup_mariadb_db
DB_PASSWD=$(grep "^Password:" "$ROMM_CREDS" | cut -d' ' -f2)
msg_ok "MariaDB configured"

msg_info "Installing uv"
curl -LsSf https://astral.sh/uv/install.sh | sh
export PATH="$HOME/.local/bin:$PATH"
msg_ok "Installed uv"

msg_info "Installing Node.js"
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
$STD apt-get install -y nodejs
msg_ok "Installed Node.js"

msg_info "Building RAHasher"
git clone --recursive --branch 1.8.1 --depth 1 https://github.com/RetroAchievements/RALibretro.git /tmp/RALibretro
sed -i '22a #include <ctime>' /tmp/RALibretro/src/Util.h
sed -i '6a #include <unistd.h>' \
  /tmp/RALibretro/src/libchdr/deps/zlib-1.3.1/gzlib.c \
  /tmp/RALibretro/src/libchdr/deps/zlib-1.3.1/gzread.c \
  /tmp/RALibretro/src/libchdr/deps/zlib-1.3.1/gzwrite.c
make -C /tmp/RALibretro HAVE_CHD=1 -f /tmp/RALibretro/Makefile.RAHasher
install -m 0755 /tmp/RALibretro/bin64/RAHasher /usr/bin/RAHasher
rm -rf /tmp/RALibretro
msg_ok "Built RAHasher"

msg_info "Cloning RomM"
ROMM_RELEASE_JSON=$(curl -fsSL https://api.github.com/repos/rommapp/romm/releases/latest)
ROMM_TAG=$(echo "$ROMM_RELEASE_JSON" | jq -r '.tag_name')
ROMM_VERSION="${ROMM_TAG#v}"
git clone --branch "$ROMM_TAG" --depth 1 https://github.com/rommapp/romm.git "$ROMM_DIR"
echo "$ROMM_VERSION" > "$ROMM_DIR/.version"
msg_ok "Cloned RomM v$ROMM_VERSION"

msg_info "Installing backend dependencies"
cd "$ROMM_DIR"
~/.local/bin/uv venv
~/.local/bin/uv sync --locked
msg_ok "Backend dependencies installed"

msg_info "Building frontend"
cd "$ROMM_DIR/frontend"
$STD npm ci --ignore-scripts --no-audit --no-fund
$STD npm run build
msg_ok "Frontend built"

msg_info "Creating directory structure"
mkdir -p "$ROMM_BASE"/{library/roms,resources,assets,config}
touch "$ROMM_BASE/config/config.yml"
msg_ok "Directories created"

msg_info "Creating environment file"
ROMM_AUTH_SECRET_KEY=$(openssl rand -hex 32)
cat > "$ROMM_DIR/.env" << EOF
ROMM_BASE_PATH=$ROMM_BASE
DB_HOST=127.0.0.1
DB_PORT=3306
DB_NAME=romm
DB_USER=romm
DB_PASSWD=$DB_PASSWD
REDIS_HOST=127.0.0.1
REDIS_PORT=6379
ROMM_AUTH_SECRET_KEY=$ROMM_AUTH_SECRET_KEY
EOF

# Add auth secret key to credentials file
echo "" >> "$ROMM_CREDS"
echo "Auth Secret Key: $ROMM_AUTH_SECRET_KEY" >> "$ROMM_CREDS"
msg_ok "Environment configured"

msg_info "Creating systemd service"
cat > /etc/systemd/system/romm.service << 'SERVICEEOF'
[Unit]
Description=RomM
After=network.target mariadb.service redis.service

[Service]
Type=simple
User=root
WorkingDirectory=/opt/romm
EnvironmentFile=/opt/romm/.env
ExecStart=/opt/romm/.venv/bin/python3 /opt/romm/backend/main.py
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
SERVICEEOF

systemctl daemon-reload
systemctl enable romm
systemctl start romm
msg_ok "RomM service started"

motd_ssh
customize

msg_ok "Completed Successfully!\n"
