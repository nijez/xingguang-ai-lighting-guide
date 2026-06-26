#!/usr/bin/env bash
set -Eeuo pipefail

XINGUANG_SKILL_INSTALLER_VERSION="2026-06-26.1"
XINGUANG_SKILL_VERSION="3.0.1"
SKILL_NAME="wainfort-ai-lighting-run"
SKILL_COMPANY="深圳市馨光智能物联有限公司"

INSTALL_ACTION="${INSTALL_ACTION:-full}"
INSTALL_DIR="${INSTALL_DIR:-$HOME/wainfort-light}"
LOG_FILE="${LOG_FILE:-/tmp/xinguang-skill-install-current.log}"
STATE_FILE="${STATE_FILE:-/tmp/xinguang-skill-install.state}"
PID_FILE="${PID_FILE:-/tmp/xinguang-skill-install.pid}"
SERVER_URL="${SERVER_URL:-http://appagent.wainfort.com/download/wainfort-server}"
WAINFORT_SERVER_SHA256="${WAINFORT_SERVER_SHA256:-49bbd86dd064baf09d1914003638969a7a937a36a5a447ea6a28bde527e3df7c}"
WAINFORT_API_PORT="${WAINFORT_API_PORT:-1888}"
WAINFORT_MILOCO_URL="${WAINFORT_MILOCO_URL:-http://127.0.0.1:1810}"
ROTATE_WAINFORT_TOKEN="${ROTATE_WAINFORT_TOKEN:-0}"

SKILL_URLS="${SKILL_URLS:-https://nijez.github.io/xingguang-ai-lighting-guide/skills/wainfort-ai-lighting-run/SKILL.md https://raw.githubusercontent.com/nijez/xingguang-ai-lighting-guide/main/skills/wainfort-ai-lighting-run/SKILL.md https://cdn.jsdelivr.net/gh/nijez/xingguang-ai-lighting-guide@main/skills/wainfort-ai-lighting-run/SKILL.md}"

ENV_FILE="$INSTALL_DIR/.env"
SERVER_BIN="$INSTALL_DIR/wainfort-server"
SERVER_PID_FILE="$INSTALL_DIR/wainfort-server.pid"
API_LOG="$INSTALL_DIR/api.log"
PUBLIC_SKILL_DIR="$INSTALL_DIR/downloads/$SKILL_NAME"
LOCAL_SKILL_DIR="$INSTALL_DIR/openclaw-skill/$SKILL_NAME"
LOCAL_SKILL_FILE="$LOCAL_SKILL_DIR/SKILL.md"
DEVICE_CACHE="$INSTALL_DIR/devices-last.json"

mkdir -p "$(dirname "$LOG_FILE")" "$INSTALL_DIR"
touch "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

log() {
  printf '[%s] %s\n' "$(date '+%F %T %Z')" "$*" >&2
}

state_mark() {
  mkdir -p "$(dirname "$STATE_FILE")"
  printf '%s %s\n' "$(date '+%F %T %Z')" "$1" >>"$STATE_FILE"
  log "STATE: $1"
}

die() {
  state_mark "ERROR: $*"
  printf '\n馨光 Skill 安装未完成\n原因：%s\n日志文件：%s\n状态文件：%s\n' "$*" "$LOG_FILE" "$STATE_FILE" >&2
  exit 1
}

have() {
  command -v "$1" >/dev/null 2>&1
}

version() {
  printf '%s\n' "$XINGUANG_SKILL_INSTALLER_VERSION"
}

status_file_has() {
  [[ -f "$STATE_FILE" ]] && grep -q "$1" "$STATE_FILE"
}

load_env_if_present() {
  if [[ -f "$ENV_FILE" ]]; then
    set -a
    # shellcheck disable=SC1090
    . "$ENV_FILE"
    set +a
  fi
}

generate_token() {
  local suffix
  if have openssl; then
    suffix="$(openssl rand -hex 18)"
  elif [[ -r /proc/sys/kernel/random/uuid ]]; then
    suffix="$(tr -d '-' </proc/sys/kernel/random/uuid)"
  elif have sha256sum; then
    suffix="$(printf '%s:%s:%s' "$(date +%s%N)" "$RANDOM" "$(hostname 2>/dev/null || true)" | sha256sum | awk '{print $1}')"
  else
    suffix="$(printf '%s%s%s' "$(date +%s)" "$RANDOM" "$RANDOM")"
  fi
  printf 'wainfort-ai-2026-%s\n' "$suffix"
}

ensure_env_file() {
  mkdir -p "$INSTALL_DIR"
  chmod 700 "$INSTALL_DIR" 2>/dev/null || true

  local token="${WAINFORT_API_TOKEN:-}"
  if [[ "$ROTATE_WAINFORT_TOKEN" != 1 && -f "$ENV_FILE" ]]; then
    token="$(grep -E '^WAINFORT_API_TOKEN=' "$ENV_FILE" 2>/dev/null | tail -n 1 | cut -d= -f2- || true)"
  fi
  if [[ -z "$token" ]]; then
    token="$(generate_token)"
  fi

  umask 077
  cat >"$ENV_FILE" <<EOF
WAINFORT_API_TOKEN=$token
WAINFORT_MILOCO_URL=$WAINFORT_MILOCO_URL
WAINFORT_MILOCO_TOKEN=${WAINFORT_MILOCO_TOKEN:-}
WAINFORT_API_PORT=$WAINFORT_API_PORT
EOF
  chmod 600 "$ENV_FILE" 2>/dev/null || true
  export WAINFORT_API_TOKEN="$token"
  export WAINFORT_MILOCO_URL
  export WAINFORT_MILOCO_TOKEN="${WAINFORT_MILOCO_TOKEN:-}"
  export WAINFORT_API_PORT
  state_mark TOKEN_CONFIGURED
}

download_file() {
  local target="$1"
  shift
  local url
  rm -f "$target"
  for url in "$@"; do
    log "尝试下载：$url"
    if curl -fL --retry 2 --connect-timeout 15 --max-time 900 "$url" -o "$target"; then
      [[ -s "$target" ]] && return 0
    fi
    log "当前下载源不可用，继续尝试下一个源"
  done
  return 1
}

download_skill() {
  mkdir -p "$PUBLIC_SKILL_DIR"
  # shellcheck disable=SC2206
  local urls=($SKILL_URLS)
  download_file "$PUBLIC_SKILL_DIR/SKILL.md" "${urls[@]}" || die "馨光 Skill 文件下载失败"

  grep -q "^name: $SKILL_NAME$" "$PUBLIC_SKILL_DIR/SKILL.md" || die "馨光 Skill 名称校验失败"
  grep -q "\"version\":\"$XINGUANG_SKILL_VERSION\"" "$PUBLIC_SKILL_DIR/SKILL.md" || die "馨光 Skill 版本校验失败"
  grep -q "$SKILL_COMPANY" "$PUBLIC_SKILL_DIR/SKILL.md" || die "馨光 Skill 公司信息校验失败"
  state_mark SKILL_DOWNLOAD_DONE
}

prepare_local_skill() {
  mkdir -p "$LOCAL_SKILL_DIR"
  cp "$PUBLIC_SKILL_DIR/SKILL.md" "$LOCAL_SKILL_FILE"
  perl -0pi -e "s/wainfort-ai-2026-你的本地Token/$WAINFORT_API_TOKEN/g" "$LOCAL_SKILL_FILE"
  chmod 700 "$LOCAL_SKILL_DIR" 2>/dev/null || true
  chmod 600 "$LOCAL_SKILL_FILE" 2>/dev/null || true
  state_mark SKILL_LOCAL_CONFIG_READY
}

openclaw_has_skills_command() {
  have openclaw || return 1
  openclaw skills --help >/dev/null 2>&1
}

install_skill_with_openclaw_command() {
  openclaw_has_skills_command || return 1

  if timeout 180s openclaw skills install "$LOCAL_SKILL_DIR" --as "$SKILL_NAME" --global; then
    return 0
  fi
  if timeout 180s openclaw skills install "$LOCAL_SKILL_DIR" --as "$SKILL_NAME"; then
    return 0
  fi
  return 1
}

reload_openclaw_best_effort() {
  have openclaw || return 0
  timeout 60s openclaw skills reload >/dev/null 2>&1 || true
  timeout 90s openclaw gateway restart >/dev/null 2>&1 || true
}

skill_install_verified() {
  have openclaw || return 1
  if timeout 60s openclaw skills info "$SKILL_NAME" >/dev/null 2>&1; then
    return 0
  fi
  timeout 60s openclaw skills list 2>/dev/null | grep -qi 'wainfort'
}

install_skill() {
  prepare_local_skill
  if install_skill_with_openclaw_command; then
    reload_openclaw_best_effort
    if skill_install_verified; then
      state_mark SKILL_INSTALL_DONE
      state_mark SKILL_INSTALL_VERIFIED
      return 0
    fi
    die "馨光 Skill 安装失败，请联系技术人员处理。"
  fi
  die "馨光 Skill 安装失败，请联系技术人员处理。"
}

verify_server_checksum() {
  if [[ -z "$WAINFORT_SERVER_SHA256" ]]; then
    log "WARNING: 当前未配置 wainfort-server 校验值，正式发布前建议补充。"
    state_mark SERVER_SHA256_NOT_CONFIGURED
    return 0
  fi

  if have sha256sum; then
    printf '%s  %s\n' "$WAINFORT_SERVER_SHA256" "$SERVER_BIN" | sha256sum -c - >/dev/null ||
      die "wainfort-server SHA256 校验失败"
    state_mark SERVER_SHA256_OK
    return 0
  fi
  if have shasum; then
    printf '%s  %s\n' "$WAINFORT_SERVER_SHA256" "$SERVER_BIN" | shasum -a 256 -c - >/dev/null ||
      die "wainfort-server SHA256 校验失败"
    state_mark SERVER_SHA256_OK
    return 0
  fi
  die "无法校验 wainfort-server 文件，请联系技术人员处理。"
}

download_server() {
  download_file "$SERVER_BIN" "$SERVER_URL" || die "wainfort-server 下载失败"
  verify_server_checksum
  chmod +x "$SERVER_BIN"
  state_mark SERVER_DOWNLOAD_DONE
}

server_process_running() {
  if [[ -f "$SERVER_PID_FILE" ]]; then
    local pid
    pid="$(cat "$SERVER_PID_FILE" 2>/dev/null || true)"
    [[ -n "$pid" ]] && ps -p "$pid" >/dev/null 2>&1 && return 0
  fi
  pgrep -f "$SERVER_BIN" >/dev/null 2>&1
}

server_status_ok() {
  curl -fsS --max-time 5 "http://127.0.0.1:$WAINFORT_API_PORT/api/status" >/dev/null 2>&1 && return 0

  local token="${WAINFORT_API_TOKEN:-}"
  [[ -n "$token" ]] && curl -fsS --max-time 5 \
    -H "Authorization: Bearer $token" \
    "http://127.0.0.1:$WAINFORT_API_PORT/api/status" >/dev/null 2>&1
}

start_server() {
  load_env_if_present
  if server_status_ok || server_process_running; then
    state_mark SERVER_ALREADY_RUNNING
    return 0
  fi

  : >"$API_LOG"
  nohup env \
    WAINFORT_API_TOKEN="$WAINFORT_API_TOKEN" \
    WAINFORT_MILOCO_URL="$WAINFORT_MILOCO_URL" \
    WAINFORT_MILOCO_TOKEN="${WAINFORT_MILOCO_TOKEN:-}" \
    WAINFORT_API_PORT="$WAINFORT_API_PORT" \
    "$SERVER_BIN" >>"$API_LOG" 2>&1 &
  printf '%s\n' "$!" >"$SERVER_PID_FILE"
  state_mark SERVER_STARTED

  local i
  for i in $(seq 1 30); do
    if server_status_ok; then
      state_mark SERVER_STATUS_OK
      return 0
    fi
    sleep 2
  done

  if server_process_running; then
    state_mark SERVER_PROCESS_RUNNING_STATUS_PENDING
    return 0
  fi
  die "wainfort-server 未能启动"
}

query_devices() {
  load_env_if_present
  rm -f "$DEVICE_CACHE"
  if curl -fsS --max-time 15 \
    -H "Authorization: Bearer $WAINFORT_API_TOKEN" \
    "http://127.0.0.1:$WAINFORT_API_PORT/api/devices" \
    -o "$DEVICE_CACHE"; then
    state_mark DEVICE_QUERY_DONE
    if grep -q 'wainft.light.rgbcwy' "$DEVICE_CACHE"; then
      state_mark XINGUANG_DEVICE_FOUND
      return 0
    fi
    state_mark XINGUANG_DEVICE_NOT_FOUND
    printf '\n未发现馨光设备，请先确认米家账号已绑定，并且馨光设备已出现在设备列表。\n'
    return 0
  fi

  state_mark DEVICE_QUERY_FAILED
  printf '\n暂时无法查询设备，请先确认米家账号已绑定，并且稍后发送“查看馨光 Skill 安装进度”。\n'
}

print_status() {
  load_env_if_present
  printf '馨光 Skill 安装进度\n\n'
  printf '检查时间：%s\n' "$(date '+%F %T %Z')"
  printf '安装器版本：%s\n' "$XINGUANG_SKILL_INSTALLER_VERSION"
  printf 'Skill 版本：%s\n' "$XINGUANG_SKILL_VERSION"
  printf '状态文件：%s\n' "$STATE_FILE"
  printf '日志文件：%s\n\n' "$LOG_FILE"

  if [[ -f "$STATE_FILE" ]]; then
    printf '最近状态：\n'
    tail -n 40 "$STATE_FILE" || true
  else
    printf '最近状态：暂未找到状态文件\n'
  fi

  printf '\n服务状态：'
  if server_status_ok || server_process_running; then
    printf '运行中\n'
  else
    printf '未确认运行\n'
  fi

  printf 'Skill 文件：'
  if [[ -f "$LOCAL_SKILL_FILE" ]] || status_file_has SKILL_INSTALL_DONE; then
    printf '已准备\n'
  else
    printf '未确认\n'
  fi

  if [[ -n "${WAINFORT_API_TOKEN:-}" ]] && (server_status_ok || server_process_running); then
    query_devices >/dev/null 2>&1 || true
  fi

  printf '馨光设备：'
  if status_file_has XINGUANG_DEVICE_FOUND; then
    printf '已发现\n'
  elif status_file_has XINGUANG_DEVICE_NOT_FOUND; then
    printf '未发现，请先确认米家账号已绑定，并且馨光设备已出现在设备列表。\n'
  else
    printf '未确认\n'
  fi

  printf '\n最近错误：\n'
  grep -Ei 'ERROR|失败|未能|无法|not found|failed|traceback' "$STATE_FILE" "$LOG_FILE" 2>/dev/null | tail -n 20 || printf '未发现明显错误\n'
}

main() {
  if [[ "$INSTALL_ACTION" == "status" ]]; then
    print_status
    return 0
  fi

  printf '%s\n' "$$" >"$PID_FILE"
  state_mark "INSTALLER_VERSION=$XINGUANG_SKILL_INSTALLER_VERSION"
  state_mark "SKILL_VERSION=$XINGUANG_SKILL_VERSION"

  ensure_env_file
  download_skill
  download_server
  start_server
  install_skill
  query_devices

  state_mark XINGUANG_SKILL_INSTALL_DONE
  printf '\n馨光 Skill 安装流程已完成\n'
  printf '安装器版本：%s\n' "$XINGUANG_SKILL_INSTALLER_VERSION"
  printf 'Skill 版本：%s\n' "$XINGUANG_SKILL_VERSION"
  printf '日志文件：%s\n' "$LOG_FILE"
  printf '状态文件：%s\n' "$STATE_FILE"
  printf '\n下一步：可以发送灯光测试语句，例如“吊顶灯带，设计个马尔代夫灯光效果。”\n'
}

main "$@"
