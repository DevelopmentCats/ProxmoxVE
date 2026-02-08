#!/usr/bin/env bash

# Copyright (c) 2021-2025 community-scripts ORG
# Author: DevelopmentCats (adapted from brandong84's Alpine script)
# License: MIT | https://github.com/community-scripts/ProxmoxVED/raw/main/LICENSE
# Source: https://github.com/rommapp/romm

source /dev/stdin <<< "$FUNCTIONS_FILE_PATH"

color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

APP="RomM"
ROMM_USER="romm"
ROMM_GROUP="romm"
ROMM_HOME="/opt/romm"
ROMM_BASE="/romm"
ROMM_ENV_DIR="/etc/romm"
ROMM_ENV_FILE="/etc/romm/romm.env"
ROMM_VERSION_FILE="/opt/romm/.version"
ROMM_CRED_FILE="/root/romm.creds"
ROMM_NGINX_CONF="/etc/nginx/nginx.conf"
ROMM_NGINX_SITE="/etc/nginx/sites-available/romm"
ROMM_NGINX_JS_DIR="/etc/nginx/js"
ROMM_INIT_BIN="/usr/local/bin/romm-init"

msg_info "Installing Dependencies"
$STD apt-get install -y \
  bash \
  ca-certificates \
  curl \
  file \
  git \
  jq \
  mariadb-server \
  mariadb-client \
  nginx \
  libnginx-mod-http-js \
  nodejs \
  npm \
  openssl \
  p7zip-full \
  redis-server \
  tar \
  tzdata \
  unzip \
  wget
msg_ok "Installed Dependencies"

msg_info "Installing build dependencies"
$STD apt-get install -y \
  build-essential \
  libffi-dev \
  libpq-dev \
  libmariadb-dev \
  libbz2-dev \
  libncurses5-dev \
  libssl-dev \
  libreadline-dev \
  libsqlite3-dev \
  zlib1g-dev \
  liblzma-dev \
  libmagic-dev
msg_ok "Installed build dependencies"

msg_info "Installing uv"
UV_TAG=$(curl -fsSL https://api.github.com/repos/astral-sh/uv/releases/latest | jq -r '.tag_name')
UV_VERSION="${UV_TAG#v}"
case "$(uname -m)" in
  x86_64) UV_ARCH="x86_64-unknown-linux-gnu" ;;
  aarch64) UV_ARCH="aarch64-unknown-linux-gnu" ;;
  *)
    msg_error "Unsupported architecture for uv."
    exit 1
    ;;
esac
curl -fsSL "https://github.com/astral-sh/uv/releases/download/${UV_TAG}/uv-${UV_ARCH}.tar.gz" -o /tmp/uv.tar.gz
tar -xzf /tmp/uv.tar.gz -C /tmp
if [[ -f /tmp/uv ]]; then
  install -m 0755 /tmp/uv /usr/local/bin/uv
else
  install -m 0755 /tmp/*/uv /usr/local/bin/uv
fi
rm -rf /tmp/uv.tar.gz /tmp/uv*
msg_ok "Installed uv ${UV_VERSION}"

msg_info "Downloading RomM"
ROMM_RELEASE_JSON=$(curl -fsSL https://api.github.com/repos/rommapp/romm/releases/latest)
ROMM_TAG=$(echo "$ROMM_RELEASE_JSON" | jq -r '.tag_name')
ROMM_VERSION="${ROMM_TAG#v}"
ROMM_TARBALL=$(echo "$ROMM_RELEASE_JSON" | jq -r '.tarball_url')
if [[ -z "$ROMM_VERSION" || "$ROMM_VERSION" == "null" || -z "$ROMM_TARBALL" || "$ROMM_TARBALL" == "null" ]]; then
  msg_error "Unable to resolve RomM release data."
  exit 1
fi
rm -rf "$ROMM_HOME"
mkdir -p "$ROMM_HOME"
curl -fsSL "$ROMM_TARBALL" | tar -xz -C "$ROMM_HOME" --strip-components=1
echo "$ROMM_VERSION" >"$ROMM_VERSION_FILE"
msg_ok "Downloaded RomM v${ROMM_VERSION}"

msg_info "Creating RomM user"
if ! id -u "$ROMM_USER" >/dev/null 2>&1; then
  useradd -r -s /bin/false -d "$ROMM_HOME" "$ROMM_USER"
fi
msg_ok "Created RomM user"

msg_info "Configuring MariaDB"
$STD systemctl enable --now mariadb
sleep 3
DB_NAME="romm"
DB_USER="romm"
DB_PASSWD=$(openssl rand -hex 16)
mariadb -u root <<EOF
CREATE DATABASE IF NOT EXISTS ${DB_NAME} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASSWD}';
GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
EOF
msg_ok "Configured MariaDB"

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

msg_info "Installing backend dependencies"
cd "$ROMM_HOME"
/usr/local/bin/uv python install 3.13
/usr/local/bin/uv venv --python 3.13
/usr/local/bin/uv sync --locked --no-cache
msg_ok "Installed backend dependencies"

msg_info "Building frontend"
cd "$ROMM_HOME/frontend"
$STD npm ci --ignore-scripts --no-audit --no-fund
$STD npm run build
msg_ok "Built frontend"

msg_info "Configuring RomM"
mkdir -p "$ROMM_BASE/library" "$ROMM_BASE/resources" "$ROMM_BASE/assets" "$ROMM_BASE/config" "$ROMM_BASE/tmp"
mkdir -p "$ROMM_BASE/library/roms"/{gbc,gba,ps,ps2,ps3,switch,n64,snes,nes,genesis,dreamcast,psp,nds,gb}
mkdir -p "$ROMM_BASE/library/bios"/{gba,ps,ps2}
mkdir -p /redis-data
touch "$ROMM_BASE/config/config.yml"
mkdir -p "$ROMM_ENV_DIR"
ROMM_AUTH_SECRET_KEY=$(openssl rand -hex 32)
cat <<EOF >"$ROMM_ENV_FILE"
ROMM_BASE_PATH=${ROMM_BASE}
ROMM_BASE_URL=http://0.0.0.0:8080
ROMM_PORT=8080
ROMM_TMP_PATH=${ROMM_BASE}/tmp
DEV_MODE=false
DEV_PORT=5000
DB_HOST=127.0.0.1
DB_PORT=3306
DB_NAME=${DB_NAME}
DB_USER=${DB_USER}
DB_PASSWD=${DB_PASSWD}
REDIS_HOST=
REDIS_PORT=6379
ROMM_AUTH_SECRET_KEY=${ROMM_AUTH_SECRET_KEY}
ENABLE_RESCAN_ON_FILESYSTEM_CHANGE=true
ENABLE_SCHEDULED_RESCAN=false
ENABLE_SCHEDULED_UPDATE_SWITCH_TITLEDB=false
ENABLE_SCHEDULED_UPDATE_LAUNCHBOX_METADATA=false
ENABLE_SCHEDULED_CONVERT_IMAGES_TO_WEBP=false
ENABLE_SCHEDULED_RETROACHIEVEMENTS_PROGRESS_SYNC=false
LOGLEVEL=INFO
EOF
ln -sfn "$ROMM_ENV_FILE" "$ROMM_HOME/.env"

cat <<EOF >"$ROMM_CRED_FILE"
RomM Credentials
=================
Database Name: ${DB_NAME}
Database User: ${DB_USER}
Database Password: ${DB_PASSWD}
Auth Secret Key: ${ROMM_AUTH_SECRET_KEY}

Library: ${ROMM_BASE}/library
Config: ${ROMM_BASE}/config/config.yml
Env File: ${ROMM_ENV_FILE}

To reconfigure: edit ${ROMM_ENV_FILE} and run 'systemctl restart romm'
EOF
chmod 600 "$ROMM_CRED_FILE"
msg_ok "Configured RomM"

msg_info "Creating gunicorn logging config"
cat <<'EOF' >"$ROMM_ENV_DIR/gunicorn-logging.conf"
[loggers]
keys=root,gunicorn.error,gunicorn.access

[handlers]
keys=error_console,access_console

[formatters]
keys=generic,access

[logger_root]
level=INFO
handlers=error_console

[logger_gunicorn.error]
level=INFO
handlers=error_console
propagate=0
qualname=gunicorn.error

[logger_gunicorn.access]
level=INFO
handlers=access_console
propagate=0
qualname=gunicorn.access

[handler_error_console]
class=StreamHandler
formatter=generic
args=(sys.stderr,)

[handler_access_console]
class=StreamHandler
formatter=access
args=(sys.stdout,)

[formatter_generic]
format=%(levelname)s:     [RomM][gunicorn][%(asctime)s] %(message)s
datefmt=%Y-%m-%d %H:%M:%S
class=logging.Formatter

[formatter_access]
format=%(levelname)s:     [RomM][gunicorn][%(asctime)s] %(message)s
class=logging.Formatter
EOF
msg_ok "Created gunicorn logging config"

msg_info "Preparing frontend assets"
mkdir -p /var/www/html/assets/romm
cp -a "$ROMM_HOME/frontend/dist/." /var/www/html/
mkdir -p /var/www/html/assets
cp -a "$ROMM_HOME/frontend/assets/." /var/www/html/assets/
ln -sfn "$ROMM_BASE/resources" /var/www/html/assets/romm/resources
ln -sfn "$ROMM_BASE/assets" /var/www/html/assets/romm/assets
msg_ok "Prepared frontend assets"

msg_info "Configuring Nginx"
mkdir -p /var/log/nginx
mkdir -p "$ROMM_NGINX_JS_DIR"
cat <<'EOF' >"$ROMM_NGINX_JS_DIR/decode.js"
// Decode a Base64 encoded string received as a query parameter named 'value',
// and return the decoded value in the response body.
function decodeBase64(r) {
  var encodedValue = r.args.value;

  if (!encodedValue) {
    r.return(400, "Missing 'value' query parameter");
    return;
  }

  try {
    var decodedValue = atob(encodedValue);
    r.return(200, decodedValue);
  } catch (e) {
    r.return(400, "Invalid Base64 encoding");
  }
}

export default { decodeBase64 };
EOF

cat <<'EOF' >"$ROMM_NGINX_SITE"
js_import /etc/nginx/js/decode.js;

map $http_x_forwarded_proto $forwardscheme {
  default $scheme;
  https https;
}

map $request_uri $coep_header {
  default        "";
  ~^/rom/.*/ejs$ "require-corp";
}
map $request_uri $coop_header {
  default        "";
  ~^/rom/.*/ejs$ "same-origin";
}

map $time_iso8601 $date {
  ~([^+]+)T $1;
}
map $time_iso8601 $time {
  ~T([0-9:]+)\+ $1;
}

map $http_user_agent $browser {
  default         "Unknown";
  "~Chrome/"      "Chrome";
  "~Firefox/"     "Firefox";
  "~Safari/"      "Safari";
  "~Edge/"        "Edge";
  "~Opera/"       "Opera";
}

map $http_user_agent $os {
  default         "Unknown";
  "~Windows NT"   "Windows";
  "~Macintosh"    "macOS";
  "~Linux"        "Linux";
  "~Android"      "Android";
  "~iPhone"       "iOS";
}

log_format romm_logs 'INFO:     [RomM][nginx][$date $time] '
  '$remote_addr | $http_x_forwarded_for | '
  '$request_method $request_uri $status | $body_bytes_sent | '
  '$browser $os | $request_time';

upstream wsgi_server {
  server unix:/tmp/gunicorn.sock;
}

server {
  root /var/www/html;
  listen 8080;
  listen [::]:8080;
  server_name _;

  access_log /var/log/nginx/romm-access.log romm_logs;
  error_log /var/log/nginx/romm-error.log;

  proxy_set_header Host $http_host;
  proxy_set_header X-Real-IP $remote_addr;
  proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
  proxy_set_header X-Forwarded-Proto $forwardscheme;

  location / {
    try_files $uri $uri/ /index.html;
    proxy_redirect off;
    add_header Access-Control-Allow-Origin *;
    add_header Access-Control-Allow-Methods *;
    add_header Access-Control-Allow-Headers *;
    add_header Cross-Origin-Embedder-Policy $coep_header;
    add_header Cross-Origin-Opener-Policy $coop_header;
  }

  location /assets {
    try_files $uri $uri/ =404;
  }

  location /openapi.json {
    proxy_pass http://wsgi_server;
  }

  location /api {
    proxy_pass http://wsgi_server;
    proxy_request_buffering off;
    proxy_buffering off;
  }

  location ~ ^/(ws|netplay) {
    proxy_pass http://wsgi_server;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
  }

  location /library/ {
    internal;
    alias ${ROMM_BASE}/library/;
  }

  location /decode {
    internal;
    js_content decode.decodeBase64;
  }

  location ~ /\.ht {
    deny all;
  }
}
EOF

# Enable site
ln -sf "$ROMM_NGINX_SITE" /etc/nginx/sites-enabled/romm
rm -f /etc/nginx/sites-enabled/default

# Update nginx.conf for larger uploads
sed -i 's/^.*client_max_body_size.*$/\tclient_max_body_size 0;/' /etc/nginx/nginx.conf || echo "client_max_body_size 0;" >> /etc/nginx/nginx.conf

$STD systemctl enable nginx
msg_ok "Configured Nginx"

msg_info "Installing RomM init script"
cat <<'EOFSCRIPT' >"$ROMM_INIT_BIN"
#!/bin/bash
set -euo pipefail

ROMM_HOME="/opt/romm"
ROMM_ENV_FILE="/etc/romm/romm.env"
ROMM_GUNICORN_LOG="/etc/romm/gunicorn-logging.conf"
BACKEND_DIR="${ROMM_HOME}/backend"

info_log() { echo "INFO:     [RomM][init] $1"; }
error_log() { echo "ERROR:    [RomM][init] $1" >&2; exit 1; }

print_banner() {
  cat <<'EOF'
    ____                  __  ___
   / __ \____  ____ ___  /  |/  /
  / /_/ / __ \/ __ `__ \/ /|_/ / 
 / _, _/ /_/ / / / / / / /  / /  
/_/ |_|\____/_/ /_/ /_/_/  /_/   

EOF
  info_log "Initializing RomM..."
}

wait_for_mariadb() {
  info_log "Waiting for MariaDB to be ready..."
  for i in {1..30}; do
    if mariadb -u root -e "SELECT 1;" >/dev/null 2>&1; then
      info_log "MariaDB is ready"
      return 0
    fi
    sleep 2
  done
  error_log "MariaDB failed to start"
}

run_startup() {
  info_log "Starting backend processes..."
  
  # Start Redis
  if [[ -z ${REDIS_HOST:-} ]]; then
    redis-server --daemonize yes --pidfile /tmp/redis.pid --dir /redis-data
    info_log "Started Redis"
  fi

  # Start Gunicorn
  cd "$BACKEND_DIR"
  source "$ROMM_HOME/.venv/bin/activate"
  gunicorn handler:app \
    --workers 2 \
    --worker-class uvicorn_worker.UvicornWorker \
    --bind unix:/tmp/gunicorn.sock \
    --log-config "$ROMM_GUNICORN_LOG" \
    --daemon \
    --pid /tmp/gunicorn.pid \
    --env-file "$ROMM_ENV_FILE"
  info_log "Started Gunicorn"

  # Start RQ Scheduler if needed
  if [[ ${ENABLE_SCHEDULED_RESCAN:-false} == "true" ]] || \
     [[ ${ENABLE_SCHEDULED_UPDATE_SWITCH_TITLEDB:-false} == "true" ]] || \
     [[ ${ENABLE_SCHEDULED_UPDATE_LAUNCHBOX_METADATA:-false} == "true" ]]; then
    rqscheduler --host 127.0.0.1 --port 6379 --db 0 \
      --pid /tmp/rqscheduler.pid \
      >/var/log/rqscheduler.log 2>&1 &
    info_log "Started RQ Scheduler"
  fi

  # Start RQ Worker
  rq worker \
    --url redis://127.0.0.1:6379/0 \
    --pid /tmp/rq_worker.pid \
    >/var/log/rq_worker.log 2>&1 &
  info_log "Started RQ Worker"

  # Start filesystem watcher if enabled
  if [[ ${ENABLE_RESCAN_ON_FILESYSTEM_CHANGE:-false} == "true" ]]; then
    python3 -m tasks.watcher \
      >/var/log/watcher.log 2>&1 &
    echo $! > /tmp/watcher.pid
    info_log "Started filesystem watcher"
  fi
}

shutdown() {
  info_log "Shutting down RomM processes..."
  for pid_file in /tmp/{gunicorn,redis,rqscheduler,rq_worker,watcher}.pid; do
    if [[ -f "$pid_file" ]]; then
      kill $(cat "$pid_file") 2>/dev/null || true
      rm -f "$pid_file"
    fi
  done
}

# Source environment
set -a
source "$ROMM_ENV_FILE"
set +a

# Generate secret if missing
if [[ -z ${ROMM_AUTH_SECRET_KEY:-} ]]; then
  ROMM_AUTH_SECRET_KEY=$(python3 -c "import secrets; print(secrets.token_hex(32))")
  export ROMM_AUTH_SECRET_KEY
  info_log "Generated ROMM_AUTH_SECRET_KEY"
fi

cd "$BACKEND_DIR" || error_log "$BACKEND_DIR not found"
source "$ROMM_HOME/.venv/bin/activate"

print_banner

trap shutdown SIGINT SIGTERM EXIT

wait_for_mariadb

info_log "Running database migrations"
if alembic upgrade head; then
  info_log "Database migrations succeeded"
else
  error_log "Failed to run database migrations"
fi

run_startup

info_log "RomM is running at http://0.0.0.0:8080"

# Keep process alive
while true; do sleep 60; done
EOFSCRIPT
chmod +x "$ROMM_INIT_BIN"
msg_ok "Installed RomM init script"

msg_info "Creating systemd service"
cat <<EOF >/etc/systemd/system/romm.service
[Unit]
Description=RomM Service
After=network.target mariadb.service
Requires=mariadb.service

[Service]
Type=simple
User=root
WorkingDirectory=$ROMM_HOME/backend
EnvironmentFile=$ROMM_ENV_FILE
ExecStart=$ROMM_INIT_BIN
Restart=on-failure
RestartSec=10
KillMode=mixed
KillSignal=SIGTERM
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
EOF

$STD systemctl daemon-reload
$STD systemctl enable romm
msg_ok "Created systemd service"

msg_info "Setting ownership"
chown -R "$ROMM_USER":"$ROMM_GROUP" "$ROMM_HOME" "$ROMM_BASE" /var/www/html /redis-data || true
chmod +x "$ROMM_HOME/.venv/bin/"*
msg_ok "Set ownership"

msg_info "Starting services"
$STD systemctl restart nginx
$STD systemctl start romm
sleep 5

# Check if services are running
if systemctl is-active --quiet romm && systemctl is-active --quiet nginx; then
  msg_ok "Services started successfully"
else
  msg_error "Failed to start services. Check 'systemctl status romm nginx'"
fi

msg_ok "Installed RomM"

motd_ssh
customize

msg_info "Cleaning up"
$STD apt-get -y autoremove
$STD apt-get -y autoclean
msg_ok "Cleaned"
