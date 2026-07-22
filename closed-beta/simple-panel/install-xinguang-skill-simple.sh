#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

XINGUANG_SIMPLE_SKILL_INSTALLER_VERSION="2026-07-22.2"
XINGUANG_SKILL_VERSION="4.0.1"
SKILL_NAME="wainfort-ai-lighting-run"

BASE_DIR="${XINGUANG_SIMPLE_BASE_DIR:-$HOME/xinguang-ai-light}"
INSTALL_DIR="${WAINFORT_INSTALL_DIR:-$HOME/wainfort-light}"
TARGET_HOME_FILE="${TARGET_HOME_FILE:-$BASE_DIR/target-home.env}"
WORK_DIR="$BASE_DIR/simple-skill-install"
LOG_FILE="$BASE_DIR/simple-skill-install.log"
HOME_JSON="$WORK_DIR/homes.json"
SKILL_DIR="$WORK_DIR/$SKILL_NAME"
SKILL_FILE="$SKILL_DIR/SKILL.md"
INSTALLED_SKILL_FILE="$HOME/.openclaw/skills/$SKILL_NAME/SKILL.md"
ENV_FILE="$INSTALL_DIR/.env"
SERVER_BIN="$INSTALL_DIR/wainfort-server"
SERVER_URL="${WAINFORT_SERVER_URL:-http://appagent.wainfort.com/download/wainfort-server}"
SERVER_SHA256="d8eb45d26474ee578f65d9a86e13a6899e408eae362bb4796d902ecb29f3aea3"
SKILL_SHA256="b438db06cfe7042d4cf8e8ddaf6b0796386befa0b76bb3c05627bc44682caba4"
WAINFORT_API_PORT="${WAINFORT_API_PORT:-1888}"
WAINFORT_MILOCO_URL="${WAINFORT_MILOCO_URL:-http://127.0.0.1:1810}"
DATA_DIR="$BASE_DIR/wainfort-data"
CONFIG_DIR="$BASE_DIR/wainfort-config"
CACHE_DIR="$BASE_DIR/wainfort-cache"
SERVICE_LOG_DIR="$BASE_DIR/wainfort-logs"
USER_SERVICE="$HOME/.config/systemd/user/xinguang-wainfort.service"
ROOT_SERVICE_NAME="xinguang-wainfort.service"
ROOT_ENV_FILE="/etc/xinguang-wainfort.env"
PUBLISH_BASE="https://nijez.github.io/xingguang-ai-lighting-guide/closed-beta/simple-panel"
RAW_BASE="https://raw.githubusercontent.com/nijez/xingguang-ai-lighting-guide/main/closed-beta/simple-panel"

setup_path() {
  export PATH="$HOME/.local/bin:$HOME/.local/share/uv/tools/miloco-cli/bin:$PATH"
  local node_bin
  node_bin="$(find "$HOME/.nvm/versions/node" -mindepth 2 -maxdepth 2 -type d -name bin 2>/dev/null | sort -V | tail -1 || true)"
  [[ -n "$node_bin" ]] && export PATH="$node_bin:$PATH"
}

initialize_runtime() {
  mkdir -p "$BASE_DIR" "$WORK_DIR" "$INSTALL_DIR" "$DATA_DIR" "$CONFIG_DIR" "$CACHE_DIR" "$SERVICE_LOG_DIR"
  chmod 700 "$BASE_DIR" "$WORK_DIR" "$INSTALL_DIR" "$DATA_DIR" "$CONFIG_DIR" "$CACHE_DIR" "$SERVICE_LOG_DIR" 2>/dev/null || true
  touch "$LOG_FILE"
  chmod 600 "$LOG_FILE" 2>/dev/null || true
  exec > >(tee -a "$LOG_FILE") 2>&1
}

die() {
  printf '\n馨光 Skill 安装失败：%s\n' "$1" >&2
  exit 1
}

have() {
  command -v "$1" >/dev/null 2>&1
}

sha256_of() {
  if have sha256sum; then
    sha256sum "$1" | awk '{print $1}'
  elif have shasum; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    return 1
  fi
}

verify_sha256() {
  local file="$1"
  local expected="$2"
  local actual
  actual="$(sha256_of "$file" 2>/dev/null || true)"
  [[ -n "$actual" && "$actual" == "$expected" ]]
}

download_fixed() {
  local target="$1"
  local expected_sha="$2"
  shift 2
  local tmp url
  tmp="$(mktemp "$WORK_DIR/download.XXXXXX")"
  for url in "$@"; do
    if curl -fL --retry 2 --retry-delay 2 --connect-timeout 10 --max-time 900 -o "$tmp" "$url" &&
      verify_sha256 "$tmp" "$expected_sha"; then
      mv "$tmp" "$target"
      return 0
    fi
  done
  rm -f "$tmp"
  return 1
}

load_target_home() {
  [[ -f "$TARGET_HOME_FILE" ]] || die "请先在面板中绑定米家账号并选择家庭"
  # shellcheck disable=SC1090
  . "$TARGET_HOME_FILE"
  XINGUANG_TARGET_HOME="${XINGUANG_TARGET_HOME:-}"
  XINGUANG_TARGET_HOME_ID="${XINGUANG_TARGET_HOME_ID:-}"
  [[ -n "$XINGUANG_TARGET_HOME" && -n "$XINGUANG_TARGET_HOME_ID" ]] ||
    die "目标家庭配置不完整，请重新选择家庭"
}

query_homes() {
  timeout 30s miloco-cli scope home list >"$HOME_JSON" 2>/dev/null || return 1
  python3 -m json.tool "$HOME_JSON" >/dev/null 2>&1
}

active_home_matches() {
  python3 - "$HOME_JSON" "$XINGUANG_TARGET_HOME_ID" "$XINGUANG_TARGET_HOME" <<'PY'
import json, sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
target_id, target_name = sys.argv[2:4]

def explicit_homes(value):
    if not isinstance(value, list):
        return []
    homes = []
    for item in value:
        if not isinstance(item, dict):
            continue
        home_id = field(item, "home_id", "homeId", "family_id", "familyId")
        name = field(item, "home_name", "homeName", "family_name", "familyName")
        if home_id and name:
            homes.append(item)
    return homes

def find_homes(value):
    homes = explicit_homes(value)
    if homes:
        return homes
    if isinstance(value, dict):
        for key in ("homes", "home_list", "families", "family_list", "data", "result"):
            if key in value:
                homes = find_homes(value[key])
                if homes:
                    return homes
    return []

def field(item, *names):
    for name in names:
        value = item.get(name)
        if value is not None and str(value) != "":
            return str(value)
    return ""

def truthy(value):
    return value is True or str(value).lower() in {"1", "true", "yes", "current", "selected", "当前", "已启用"}

homes = find_homes(data)
for item in homes:
    home_id = field(item, "home_id", "homeId", "family_id", "familyId")
    name = field(item, "home_name", "homeName", "family_name", "familyName")
    active = item.get("in_use", item.get("inUse", item.get("is_in_use", item.get("current", item.get("selected", False)))))
    if truthy(active) and home_id == target_id and name == target_name:
        raise SystemExit(0)
raise SystemExit(1)
PY
}

ensure_selected_home_active() {
  query_homes || die "无法读取米家家庭列表"
  active_home_matches && return 0

  timeout 60s miloco-cli scope home switch "$XINGUANG_TARGET_HOME_ID" >/dev/null 2>&1 ||
    die "无法切换到已选择的家庭"

  local attempt
  for attempt in $(seq 1 15); do
    sleep 2
    if query_homes && active_home_matches; then
      return 0
    fi
  done
  die "家庭切换后未能确认当前家庭"
}

read_miloco_token() {
  local config="$HOME/.openclaw/miloco/config.json"
  [[ -f "$config" ]] || return 1
  python3 - "$config" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
print((data.get("server") or {}).get("token") or data.get("token") or "")
PY
}

read_env_value() {
  local file="$1"
  local key="$2"
  local reader=(cat "$file")
  [[ "$file" == /etc/* ]] && reader=(sudo cat "$file")
  "${reader[@]}" 2>/dev/null | awk -F= -v key="$key" '$1 == key {sub(/^[^=]*=/, ""); value=$0} END {print value}'
}

generate_token() {
  if have openssl; then
    printf 'wainfort-ai-2026-%s\n' "$(openssl rand -hex 18)"
  else
    printf 'wainfort-ai-2026-%s\n' "$(tr -d '-' </proc/sys/kernel/random/uuid)"
  fi
}

prepare_environment() {
  local existing_token=""
  local miloco_token=""
  if sudo test -f "$ROOT_ENV_FILE" 2>/dev/null; then
    existing_token="$(read_env_value "$ROOT_ENV_FILE" WAINFORT_API_TOKEN || true)"
  fi
  if [[ -z "$existing_token" && -f "$ENV_FILE" ]]; then
    existing_token="$(read_env_value "$ENV_FILE" WAINFORT_API_TOKEN || true)"
  fi
  [[ -n "$existing_token" ]] || existing_token="$(generate_token)"
  miloco_token="$(read_miloco_token 2>/dev/null || true)"
  [[ -n "$miloco_token" ]] || die "未读取到 Miloco 服务凭据，请先修复 Miloco 2.0"

  cat >"$ENV_FILE" <<EOF
WAINFORT_API_TOKEN=$existing_token
WAINFORT_MILOCO_TOKEN=$miloco_token
WAINFORT_MILOCO_URL=$WAINFORT_MILOCO_URL
WAINFORT_API_PORT=$WAINFORT_API_PORT
WAINFORT_DATA_DIR=$DATA_DIR
WAINFORT_CONFIG_DIR=$CONFIG_DIR
WAINFORT_CACHE_DIR=$CACHE_DIR
WAINFORT_LOG_DIR=$SERVICE_LOG_DIR
EOF
  chmod 600 "$ENV_FILE"
  export WAINFORT_API_TOKEN="$existing_token"
  export WAINFORT_MILOCO_TOKEN="$miloco_token"
}

download_assets() {
  mkdir -p "$SKILL_DIR"
  download_fixed "$SKILL_FILE" "$SKILL_SHA256" \
    "$PUBLISH_BASE/skills/$SKILL_NAME/SKILL.md" \
    "$RAW_BASE/skills/$SKILL_NAME/SKILL.md" || die "馨光 Skill 文件下载或校验失败"

  download_fixed "$SERVER_BIN" "$SERVER_SHA256" "$SERVER_URL" ||
    die "灯光服务下载或校验失败"
  chmod 700 "$SERVER_BIN"

  WAINFORT_API_TOKEN="$WAINFORT_API_TOKEN" python3 - "$SKILL_FILE" <<'PY'
import os, sys
path = sys.argv[1]
token = os.environ["WAINFORT_API_TOKEN"]
text = open(path, encoding="utf-8").read()
text = text.replace("wainfort-ai-2026-你的本地Token", token)
text = text.replace("你自定义的APIToken", token)
text = text.replace("你的APIToken", token)
open(path, "w", encoding="utf-8").write(text)
PY
  chmod 600 "$SKILL_FILE"
  grep -q '"version":"4.0.1"' "$SKILL_FILE" || die "馨光 Skill 版本校验失败"
  ! grep -qE 'wainfort-ai-2026-你的本地Token|你自定义的APIToken|你的APIToken' "$SKILL_FILE" ||
    die "馨光 Skill 本地配置未完成"
}

write_user_service() {
  mkdir -p "$(dirname "$USER_SERVICE")"
  cat >"$USER_SERVICE" <<EOF
[Unit]
Description=Xinguang Wainfort Service
After=network.target

[Service]
Type=simple
WorkingDirectory=$INSTALL_DIR
EnvironmentFile=$ENV_FILE
Environment=HOME=$HOME
Environment=XDG_DATA_HOME=$DATA_DIR
Environment=XDG_CONFIG_HOME=$CONFIG_DIR
Environment=XDG_CACHE_HOME=$CACHE_DIR
ExecStart=$SERVER_BIN --data-dir $DATA_DIR
Restart=always
RestartSec=3

[Install]
WantedBy=default.target
EOF
  chmod 600 "$USER_SERVICE"
  systemctl --user daemon-reload
  systemctl --user enable xinguang-wainfort.service
  systemctl --user restart xinguang-wainfort.service
}

write_root_service() {
  local root_data="/var/lib/xinguang-wainfort"
  local root_config="$root_data/config"
  local root_cache="/var/cache/xinguang-wainfort"
  local root_logs="/var/log/xinguang-wainfort"
  local root_bin_dir="/usr/local/lib/xinguang"
  local root_bin="$root_bin_dir/wainfort-server"
  local root_service="/etc/systemd/system/$ROOT_SERVICE_NAME"
  local path_value="$PATH"
  sudo mkdir -p "$root_data" "$root_config" "$root_cache" "$root_logs" "$root_bin_dir"
  sudo install -o root -g root -m 0755 "$SERVER_BIN" "$root_bin"
  printf '%s\n' \
    "WAINFORT_API_TOKEN=$WAINFORT_API_TOKEN" \
    "WAINFORT_MILOCO_TOKEN=$WAINFORT_MILOCO_TOKEN" \
    "WAINFORT_MILOCO_URL=$WAINFORT_MILOCO_URL" \
    "WAINFORT_API_PORT=$WAINFORT_API_PORT" \
    "WAINFORT_DATA_DIR=$root_data" \
    "WAINFORT_CONFIG_DIR=$root_config" \
    "WAINFORT_CACHE_DIR=$root_cache" \
    "WAINFORT_LOG_DIR=$root_logs" \
    "HOME=$root_data" \
    "XDG_DATA_HOME=$root_data" \
    "XDG_CONFIG_HOME=$root_config" \
    "XDG_CACHE_HOME=$root_cache" \
    "PATH=$path_value" | sudo tee "$ROOT_ENV_FILE" >/dev/null
  sudo chmod 600 "$ROOT_ENV_FILE"
  printf '%s\n' \
    '[Unit]' \
    'Description=Xinguang Wainfort Service' \
    'After=network.target' \
    '' \
    '[Service]' \
    'Type=simple' \
    'User=root' \
    "WorkingDirectory=$root_data" \
    "EnvironmentFile=$ROOT_ENV_FILE" \
    "ExecStart=$root_bin --data-dir $root_data" \
    'Restart=always' \
    'RestartSec=3' \
    'NoNewPrivileges=true' \
    'ProtectSystem=full' \
    "ReadWritePaths=$root_data $root_cache $root_logs" \
    '' \
    '[Install]' \
    'WantedBy=multi-user.target' | sudo tee "$root_service" >/dev/null
  sudo chmod 644 "$root_service"
  sudo systemctl daemon-reload
  sudo systemctl enable "$ROOT_SERVICE_NAME"
  sudo systemctl restart "$ROOT_SERVICE_NAME"
}

service_auth_ok() {
  local code
  code="$(curl -sS --max-time 10 -o /dev/null -w '%{http_code}' \
    -H "Authorization: Bearer $WAINFORT_API_TOKEN" \
    "http://127.0.0.1:$WAINFORT_API_PORT/api/devices" 2>/dev/null || true)"
  [[ "$code" == 200 ]]
}

wait_for_service() {
  local attempt
  for attempt in $(seq 1 30); do
    service_auth_ok && return 0
    sleep 2
  done
  return 1
}

install_service() {
  if sudo systemctl is-active --quiet "$ROOT_SERVICE_NAME" 2>/dev/null ||
    sudo systemctl is-enabled --quiet "$ROOT_SERVICE_NAME" 2>/dev/null; then
    write_root_service
    wait_for_service || die "灯光服务启动后认证检查失败"
    return 0
  fi

  if write_user_service >/dev/null 2>&1 && wait_for_service; then
    return 0
  fi

  systemctl --user disable --now xinguang-wainfort.service >/dev/null 2>&1 || true
  write_root_service
  wait_for_service || die "灯光服务启动后认证检查失败"
}

skill_registered() {
  timeout 60s openclaw skills info "$SKILL_NAME" >/dev/null 2>&1 && return 0
  timeout 60s openclaw skills list 2>/dev/null | grep -Fqi "$SKILL_NAME"
}

wait_for_gateway() {
  local attempt
  for attempt in $(seq 1 30); do
    if timeout 30s openclaw gateway status --deep >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  return 1
}

install_skill() {
  local installed=0
  if timeout 180s openclaw skills install "$SKILL_DIR" --as "$SKILL_NAME" --global >/dev/null 2>&1; then
    installed=1
  elif timeout 180s openclaw skills install "$SKILL_DIR" --as "$SKILL_NAME" >/dev/null 2>&1; then
    installed=1
  fi
  ((installed == 1)) || die "龙虾未能安装馨光 Skill"
  timeout 60s openclaw skills reload >/dev/null 2>&1 || true
  timeout 90s openclaw gateway restart >/dev/null 2>&1 || true
  wait_for_gateway || die "龙虾后台服务未能恢复"
  skill_registered || die "馨光 Skill 安装后未在龙虾中注册"
  [[ -f "$INSTALLED_SKILL_FILE" ]] || die "馨光 Skill 安装文件不存在"
  chmod 600 "$INSTALLED_SKILL_FILE" 2>/dev/null || die "馨光 Skill 安装文件权限设置失败"
  grep -q '"version":"4.0.1"' "$INSTALLED_SKILL_FILE" || die "馨光 Skill 安装版本不正确"
}

status() {
  setup_path
  [[ -f "$INSTALLED_SKILL_FILE" ]] || return 1
  grep -q '"version":"4.0.1"' "$INSTALLED_SKILL_FILE" || return 1
  wait_for_gateway || return 1
  skill_registered || return 1
  prepare_environment >/dev/null 2>&1 || return 1
  service_auth_ok
}

main() {
  setup_path
  initialize_runtime
  [[ "$(uname -s)" == Linux ]] || die "仅支持腾讯云 Linux 龙虾服务器"
  have openclaw || die "未检测到龙虾环境"
  have miloco-cli || die "未检测到 Miloco 2.0"
  have python3 || die "未检测到 Python 3"
  have timeout || die "缺少 timeout 命令"

  case "${1:-install}" in
    version)
      printf '%s\n' "$XINGUANG_SIMPLE_SKILL_INSTALLER_VERSION"
      ;;
    status)
      status
      ;;
    install)
      printf '正在安装馨光 Skill，请稍候。\n'
      load_target_home
      ensure_selected_home_active
      prepare_environment
      download_assets
      install_service
      install_skill
      service_auth_ok || die "灯光服务认证检查失败"
      printf '\n馨光 Skill 安装完成。\n'
      ;;
    *)
      die "未知操作"
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then
  main "$@"
fi
