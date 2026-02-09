#!/usr/bin/env bash
source <(curl -fsSL https://raw.githubusercontent.com/DevelopmentCats/ProxmoxVE/main/misc/build.func)
# Copyright (c) 2021-2026 community-scripts ORG
# Author: DevelopmentCats
# License: MIT | https://github.com/DevelopmentCats/ProxmoxVE/raw/main/LICENSE
# Source: https://github.com/rommapp/romm

APP="RomM"
var_tags="${var_tags:-media;utility}"
var_cpu="${var_cpu:-2}"
var_ram="${var_ram:-4096}"
var_disk="${var_disk:-50}"
var_os="${var_os:-debian}"
var_version="${var_version:-12}"
var_unprivileged="${var_unprivileged:-1}"

header_info "$APP"
variables
color
catch_errors

function update_script() {
  header_info
  check_container_storage
  check_container_resources

  if [[ ! -d /opt/romm ]]; then
    msg_error "No ${APP} Installation Found!"
    exit
  fi

  ROMM_VERSION_FILE="/opt/romm/.version"
  CURRENT_VERSION=$(cat "$ROMM_VERSION_FILE" 2>/dev/null || echo "unknown")
  
  ROMM_RELEASE_JSON=$(curl -fsSL https://api.github.com/repos/rommapp/romm/releases/latest)
  ROMM_TAG=$(echo "$ROMM_RELEASE_JSON" | jq -r '.tag_name')
  LATEST_VERSION="${ROMM_TAG#v}"
  
  if [[ "$CURRENT_VERSION" == "$LATEST_VERSION" ]]; then
    msg_ok "No update required. ${APP} is already at v${LATEST_VERSION}"
    exit
  fi

  msg_info "Updating ${APP} from v${CURRENT_VERSION} to v${LATEST_VERSION}"
  
  msg_info "Stopping ${APP} service"
  systemctl stop romm
  msg_ok "Stopped ${APP} service"
  
  msg_info "Downloading RomM v${LATEST_VERSION}"
  ROMM_TARBALL=$(echo "$ROMM_RELEASE_JSON" | jq -r '.tarball_url')
  curl -fsSL "$ROMM_TARBALL" | tar -xz -C /opt/romm --strip-components=1 --overwrite
  echo "$LATEST_VERSION" > "$ROMM_VERSION_FILE"
  msg_ok "Downloaded RomM v${LATEST_VERSION}"
  
  msg_info "Updating backend dependencies"
  cd /opt/romm
  /usr/local/bin/uv sync --locked --no-cache
  msg_ok "Updated backend dependencies"
  
  msg_info "Rebuilding frontend"
  cd /opt/romm/frontend
  npm ci --ignore-scripts --no-audit --no-fund
  npm run build
  msg_ok "Rebuilt frontend"
  
  msg_info "Updating frontend assets"
  rm -rf /var/www/html/*
  cp -a /opt/romm/frontend/dist/. /var/www/html/
  mkdir -p /var/www/html/assets
  cp -a /opt/romm/frontend/assets/. /var/www/html/assets/
  ln -sfn /romm/resources /var/www/html/assets/romm/resources
  ln -sfn /romm/assets /var/www/html/assets/romm/assets
  msg_ok "Updated frontend assets"
  
  msg_info "Running database migrations"
  cd /opt/romm/backend
  source /opt/romm/.venv/bin/activate
  alembic upgrade head
  msg_ok "Ran database migrations"
  
  msg_info "Starting ${APP} service"
  systemctl start romm
  msg_ok "Started ${APP} service"
  
  msg_ok "Updated ${APP} to v${LATEST_VERSION}"
  exit
}

start
build_container
description

msg_ok "Completed Successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
echo -e "${INFO}${YW} Access it using the following URL:${CL}"
echo -e "${TAB}${GATEWAY}${BGN}http://${IP}:8080${CL}"
