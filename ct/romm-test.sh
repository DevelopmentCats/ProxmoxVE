#!/usr/bin/env bash

# TEST VERSION - Sources from DevelopmentCats fork (specific commit to bypass cache)
source <(curl -s https://raw.githubusercontent.com/DevelopmentCats/ProxmoxVE/16092df02/misc/build.func)

# Copyright (c) 2021-2026 community-scripts ORG
# Author: DevelopmentCats
# License: MIT | https://github.com/DevelopmentCats/ProxmoxVE/raw/branch/main/LICENSE
# Source: https://git.chesher.xyz/cat/romm-proxmox-ve-script

APP="RomM"
var_tags="media;utility"
var_cpu="4"
var_ram="2048"
var_disk="10"
var_os="debian"
var_version="12"
var_unprivileged="1"

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
  
  msg_info "Pulling latest changes"
  cd /opt/romm
  git fetch --all --tags
  git checkout "tags/${ROMM_TAG}" -b "release-${ROMM_TAG}"
  msg_ok "Updated to ${ROMM_TAG}"
  
  msg_info "Installing Python dependencies"
  /opt/romm/.venv/bin/pip install -r requirements.txt --upgrade
  msg_ok "Dependencies updated"
  
  msg_info "Updating frontend"
  cd /opt/romm-frontend
  git fetch --all --tags
  git checkout "tags/${ROMM_TAG}" -b "release-${ROMM_TAG}"
  npm install
  npm run build
  msg_ok "Frontend updated"
  
  echo "$LATEST_VERSION" > "$ROMM_VERSION_FILE"
  
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
echo -e "🚀 ${CL}${BL}${APP} setup has been successfully initialized!${CL}"
echo -e "💡 ${YW}Access it using the following URL:${CL}"
echo -e "🌐 ${GN}http://${IP}:8080${CL}\n"
