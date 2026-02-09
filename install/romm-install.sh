#!/usr/bin/env bash

# Copyright (c) 2021-2026 community-scripts ORG
# Author: DevelopmentCats
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
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
ROMM_PORT="8080"

msg_info "Installing Dependencies"
$STD apt-get install -y \
  git \
  curl \
  build-essential \
  mariadb-server \
  redis-server \
  nginx \
  libnginx-mod-http-js \
  libmariadb-dev \
  libpq-dev \
  libmagic-dev \
  libpcre3-dev \
  zlib1g-dev \
  openssl \
  gettext-base
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

msg_info "Building nginx zip module"
(
  NGINX_VERSION=$(nginx -v 2>&1 | grep -oP '(?<=nginx/)\d+\.\d+\.\d+')
  MOD_ZIP_COMMIT="a9f9afa441117831cc712a832c98408b3f0416f6"
  git clone https://github.com/evanmiller/mod_zip.git /tmp/mod_zip
  cd /tmp/mod_zip && git checkout "$MOD_ZIP_COMMIT"
  git clone --branch "release-${NGINX_VERSION}" --depth 1 https://github.com/nginx/nginx.git /tmp/nginx
  cd /tmp/nginx
  ./auto/configure --with-compat --add-dynamic-module=/tmp/mod_zip/
  make -f ./objs/Makefile modules
  install -m 0644 /tmp/nginx/objs/ngx_http_zip_module.so /usr/lib/nginx/modules/
)
rm -rf /tmp/mod_zip /tmp/nginx
msg_ok "Built nginx zip module"

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

msg_info "Setting up frontend"
mkdir -p /var/www/html
rm -rf /var/www/html/*
cp -a "$ROMM_DIR/frontend/dist/." /var/www/html/
mkdir -p /var/www/html/assets
cp -a "$ROMM_DIR/frontend/assets/." /var/www/html/assets/
msg_ok "Frontend installed"

msg_info "Creating directory structure"
mkdir -p "$ROMM_BASE"/{library/roms,resources,assets,config}
touch "$ROMM_BASE/config/config.yml"
mkdir -p /var/www/html/assets/romm
ln -sfn "$ROMM_BASE/resources" /var/www/html/assets/romm/resources
ln -sfn "$ROMM_BASE/assets" /var/www/html/assets/romm/assets
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

echo "" >> "$ROMM_CREDS"
echo "Auth Secret Key: $ROMM_AUTH_SECRET_KEY" >> "$ROMM_CREDS"
msg_ok "Environment configured"

msg_info "Configuring Nginx"
mkdir -p /etc/nginx/js
cp "$ROMM_DIR/docker/nginx/js/decode.js" /etc/nginx/js/

cp "$ROMM_DIR/docker/nginx/default.conf" /etc/nginx/nginx.conf
sed -i "s|modules/ngx_http_js_module.so|/usr/lib/nginx/modules/ngx_http_js_module.so|g" /etc/nginx/nginx.conf
sed -i "s|modules/ngx_http_zip_module.so|/usr/lib/nginx/modules/ngx_http_zip_module.so|g" /etc/nginx/nginx.conf
sed -i "s|pid /tmp/nginx.pid;|pid /run/nginx.pid;|g" /etc/nginx/nginx.conf
sed -i "s|access_log /dev/stdout|access_log /var/log/nginx/access.log|g" /etc/nginx/nginx.conf
sed -i "s|error_log /dev/stderr|error_log /var/log/nginx/error.log|g" /etc/nginx/nginx.conf

mkdir -p /etc/nginx/conf.d
export ROMM_BASE_PATH="$ROMM_BASE"
envsubst '${ROMM_BASE_PATH}' < "$ROMM_DIR/docker/nginx/templates/default.conf.template" | \
  sed "s/\${ROMM_PORT}/$ROMM_PORT/g" | \
  sed "s/\${IPV6_LISTEN}//g" | \
  sed 's/server_name localhost;/server_name _;/g' > /etc/nginx/conf.d/romm.conf

systemctl enable nginx
msg_ok "Nginx configured"

msg_info "Running database migrations"
cd "$ROMM_DIR/backend"
source "$ROMM_DIR/.venv/bin/activate"
alembic upgrade head
deactivate
msg_ok "Database migrations complete"

msg_info "Creating systemd service"
cat > /etc/systemd/system/romm.service << 'SERVICEEOF'
[Unit]
Description=RomM
After=network.target mariadb.service redis.service

[Service]
Type=simple
User=root
WorkingDirectory=/opt/romm/backend
EnvironmentFile=/opt/romm/.env
Environment="PYTHONUNBUFFERED=1"
Environment="PYTHONDONTWRITEBYTECODE=1"
ExecStart=/opt/romm/.venv/bin/gunicorn \
  --bind=unix:/tmp/gunicorn.sock \
  --forwarded-allow-ips="*" \
  --worker-class uvicorn_worker.UvicornWorker \
  --workers 1 \
  --timeout 300 \
  --keep-alive 2 \
  --max-requests 1000 \
  --max-requests-jitter 100 \
  --worker-connections 1000 \
  --access-logfile - \
  --error-logfile - \
  main:app
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
SERVICEEOF

systemctl daemon-reload
systemctl enable romm
systemctl start romm
msg_ok "RomM service started"

msg_info "Creating RomM worker service"
cat > /etc/systemd/system/romm-worker.service << 'WORKEREOF'
[Unit]
Description=RomM Worker
After=network.target mariadb.service redis.service

[Service]
Type=simple
User=root
WorkingDirectory=/opt/romm/backend
EnvironmentFile=/opt/romm/.env
Environment="PYTHONUNBUFFERED=1"
Environment="PYTHONDONTWRITEBYTECODE=1"
ExecStart=/opt/romm/.venv/bin/rq worker \
  --url redis://localhost:6379 \
  default low_prio \
  --with-scheduler \
  --worker-class rq.worker.Worker
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
WORKEREOF

systemctl daemon-reload
systemctl enable romm-worker
systemctl start romm-worker
msg_ok "RomM worker service started"

msg_info "Starting Nginx"
systemctl restart nginx
msg_ok "Nginx started"

motd_ssh
customize

msg_ok "Completed Successfully!\n"
