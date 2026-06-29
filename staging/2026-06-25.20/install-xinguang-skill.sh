#!/usr/bin/env bash
set -Eeuo pipefail

XINGUANG_SKILL_INSTALLER_VERSION="2026-06-26.9"
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
WAINFORT_DATA_DIR="${WAINFORT_DATA_DIR:-$INSTALL_DIR/data}"
WAINFORT_LOG_DIR="${WAINFORT_LOG_DIR:-$INSTALL_DIR/logs}"
ROTATE_WAINFORT_TOKEN="${ROTATE_WAINFORT_TOKEN:-0}"
XINGUANG_TARGET_HOME="${XINGUANG_TARGET_HOME:-}"
LIGHT_API_SUCCESS="${LIGHT_API_SUCCESS:-unknown}"
LIGHT_PHYSICAL_RESULT="${LIGHT_PHYSICAL_RESULT:-}"
LIGHT_TEST_MODE="${LIGHT_TEST_MODE:-single-shot}"
LIGHT_TEST_UNSTABLE="${LIGHT_TEST_UNSTABLE:-0}"

SKILL_URLS="${SKILL_URLS:-https://nijez.github.io/xingguang-ai-lighting-guide/staging/2026-06-25.20/skills/wainfort-ai-lighting-run/SKILL.md https://nijez.github.io/xingguang-ai-lighting-guide/staging/2026-06-25.20/wainfort-ai-lighting-run-skill.txt https://nijez.github.io/xingguang-ai-lighting-guide/staging/2026-06-25.20/skills/wainfort-ai-lighting-run/SKILL.md https://nijez.github.io/xingguang-ai-lighting-guide/staging/2026-06-25.20/skills/wainfort-ai-lighting-run/SKILL.md}"

ENV_FILE="$INSTALL_DIR/.env"
SERVER_BIN="$INSTALL_DIR/wainfort-server"
SERVER_PID_FILE="$INSTALL_DIR/wainfort-server.pid"
API_LOG="$INSTALL_DIR/api.log"
PUBLIC_SKILL_DIR="$INSTALL_DIR/downloads/$SKILL_NAME"
LOCAL_SKILL_DIR="${LOCAL_SKILL_DIR:-/tmp/xinguang-skill/$SKILL_NAME}"
LOCAL_SKILL_FILE="$LOCAL_SKILL_DIR/SKILL.md"
DEVICE_CACHE="$INSTALL_DIR/devices-last.json"
HOME_LIST_CACHE="$INSTALL_DIR/homes-last.json"
CURRENT_HOME_CACHE="$INSTALL_DIR/current-home-last.txt"
HOME_SWITCH_RESULT="$INSTALL_DIR/home-switch-result.txt"
TARGET_HOME_FILE="$INSTALL_DIR/target-home.env"
DEVICE_REPORT="$INSTALL_DIR/device-report.txt"

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
  printf '\n馨光 Skill 暂时无法继续，请联系工作人员处理。\n' >&2
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
WAINFORT_DATA_DIR=$WAINFORT_DATA_DIR
WAINFORT_LOG_DIR=$WAINFORT_LOG_DIR
EOF
  chmod 600 "$ENV_FILE" 2>/dev/null || true
  export WAINFORT_API_TOKEN="$token"
  export WAINFORT_MILOCO_URL
  export WAINFORT_MILOCO_TOKEN="${WAINFORT_MILOCO_TOKEN:-}"
  export WAINFORT_API_PORT
  export WAINFORT_DATA_DIR
  export WAINFORT_LOG_DIR
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
    die "馨光 Skill 安装失败，请联系工作人员处理。"
  fi
  die "馨光 Skill 安装失败，请联系工作人员处理。"
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
  die "无法校验 wainfort-server 文件，请联系工作人员处理。"
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

server_data_dir_unsupported() {
  [[ -f "$API_LOG" ]] || return 1
  grep -Eq '/root/汤剑的文件夹|/root/.+AI设计灯光|/root/' "$API_LOG" || return 1
  grep -Eiq 'permission denied|权限|denied|EACCES|operation not permitted' "$API_LOG"
}

fail_server_data_dir_unsupported() {
  state_mark WAINFORT_SERVER_DATA_DIR_UNSUPPORTED
  die "灯光服务暂时无法启动"
}

start_server() {
  load_env_if_present
  printf '正在准备灯光服务。\n'
  if server_status_ok; then
    state_mark SERVER_ALREADY_RUNNING
    state_mark WAINFORT_SERVER_READY
    printf '灯光服务已就绪。\n'
    return 0
  fi
  if server_process_running; then
    state_mark SERVER_ALREADY_RUNNING
    return 0
  fi

  mkdir -p "$WAINFORT_DATA_DIR" "$WAINFORT_LOG_DIR"
  : >"$API_LOG"
  nohup env \
    WAINFORT_API_TOKEN="$WAINFORT_API_TOKEN" \
    WAINFORT_MILOCO_URL="$WAINFORT_MILOCO_URL" \
    WAINFORT_MILOCO_TOKEN="${WAINFORT_MILOCO_TOKEN:-}" \
    WAINFORT_API_PORT="$WAINFORT_API_PORT" \
    WAINFORT_DATA_DIR="$WAINFORT_DATA_DIR" \
    WAINFORT_LOG_DIR="$WAINFORT_LOG_DIR" \
    WAINFORT_HOME="$WAINFORT_DATA_DIR" \
    "$SERVER_BIN" >>"$API_LOG" 2>&1 &
  printf '%s\n' "$!" >"$SERVER_PID_FILE"
  state_mark SERVER_STARTED

  local i
  for i in $(seq 1 30); do
    if server_data_dir_unsupported; then
      fail_server_data_dir_unsupported
    fi
    if server_status_ok; then
      state_mark SERVER_STATUS_OK
      state_mark WAINFORT_SERVER_READY
      printf '灯光服务已就绪。\n'
      return 0
    fi
    sleep 2
  done

  if server_data_dir_unsupported; then
    fail_server_data_dir_unsupported
  fi

  if server_process_running; then
    state_mark SERVER_PROCESS_RUNNING_STATUS_PENDING
    return 0
  fi
  state_mark WAINFORT_SERVER_START_FAILED
  printf '灯光服务暂时无法启动，请联系工作人员处理。\n' >&2
  exit 1
}

query_home_list() {
  load_env_if_present
  rm -f "$HOME_LIST_CACHE"
  local tmp="$HOME_LIST_CACHE.tmp"

  if have miloco-cli; then
    local args
    for args in \
      "scope home list" \
      "scope home list --json" \
      "scope homes list --json" \
      "home list --json" \
      "homes list --json" \
      "family list --json" \
      "families list --json" \
      "account homes --json" \
      "account families --json"
    do
      if timeout 25s miloco-cli $args >"$tmp" 2>/dev/null && [[ -s "$tmp" ]] && python3 -m json.tool "$tmp" >/dev/null 2>&1; then
        mv "$tmp" "$HOME_LIST_CACHE"
        return 0
      fi
    done
  fi

  rm -f "$tmp"
  state_mark HOME_LIST_QUERY_FAILED
  return 1
}

home_python() {
  [[ -f "$HOME_LIST_CACHE" ]] || {
    return 1
  }
  python3 - "$HOME_LIST_CACHE" "$@"
}

home_list_count() {
  home_python count <<'PY' || printf '0\n'
import json
import sys

path = sys.argv[1]
mode = sys.argv[2]
try:
    data = json.load(open(path, "r", encoding="utf-8"))
except Exception:
    print(0)
    raise SystemExit

home_keys = {
    "home_id", "homeId", "home_name", "homeName",
    "family_id", "familyId", "family_name", "familyName",
}

def candidates(value, parent_key=""):
    if isinstance(value, list):
        if value and all(isinstance(item, dict) for item in value):
            parent = parent_key.lower()
            if "home" in parent or "famil" in parent:
                yield value
            elif any(home_keys.intersection(item.keys()) for item in value):
                yield value
        for item in value:
            yield from candidates(item, parent_key)
    elif isinstance(value, dict):
        for key, child in value.items():
            yield from candidates(child, str(key))

groups = list(candidates(data))
print(max((len(group) for group in groups), default=0))
PY
}

print_home_list() {
  home_python list <<'PY' || true
import json
import sys

path = sys.argv[1]
mode = sys.argv[2]
try:
    data = json.load(open(path, "r", encoding="utf-8"))
except Exception:
    raise SystemExit

home_keys = {
    "home_id", "homeId", "home_name", "homeName",
    "family_id", "familyId", "family_name", "familyName",
}

def candidates(value, parent_key=""):
    if isinstance(value, list):
        if value and all(isinstance(item, dict) for item in value):
            parent = parent_key.lower()
            if "home" in parent or "famil" in parent:
                yield value
            elif any(home_keys.intersection(item.keys()) for item in value):
                yield value
        for item in value:
            yield from candidates(item, parent_key)
    elif isinstance(value, dict):
        for key, child in value.items():
            yield from candidates(child, str(key))

groups = list(candidates(data))
if not groups:
    raise SystemExit

homes = max(groups, key=len)
for index, item in enumerate(homes, 1):
    name = (
        item.get("home_name") or item.get("homeName") or
        item.get("family_name") or item.get("familyName") or
        item.get("name") or "未命名家庭"
    )
    home_id = (
        item.get("home_id") or item.get("homeId") or
        item.get("family_id") or item.get("familyId") or
        item.get("id") or ""
    )
    suffix = f"（{home_id}）" if home_id else ""
    in_use = item.get("in_use", item.get("inUse", item.get("current", item.get("selected", False))))
    active = "；当前启用" if str(in_use).lower() in ("1", "true", "yes", "已启用") else ""
    print(f"{index}. {name}{suffix}{active}")
PY
}

target_home_info() {
  home_python find "$XINGUANG_TARGET_HOME" <<'PY'
import json
import sys

path = sys.argv[1]
mode = sys.argv[2]
target = sys.argv[3]
data = json.load(open(path, "r", encoding="utf-8"))

home_keys = {
    "home_id", "homeId", "home_name", "homeName",
    "family_id", "familyId", "family_name", "familyName",
}

def candidates(value, parent_key=""):
    if isinstance(value, list):
        if value and all(isinstance(item, dict) for item in value):
            parent = parent_key.lower()
            if "home" in parent or "famil" in parent:
                yield value
            elif any(home_keys.intersection(item.keys()) for item in value):
                yield value
        for item in value:
            yield from candidates(item, parent_key)
    elif isinstance(value, dict):
        for key, child in value.items():
            yield from candidates(child, str(key))

def field(item, *names):
    for name in names:
        value = item.get(name)
        if value is not None and str(value) != "":
            return str(value)
    return ""

homes = []
for group in candidates(data):
    if len(group) > len(homes):
        homes = group

for item in homes:
    name = field(item, "home_name", "homeName", "family_name", "familyName", "name")
    home_id = field(item, "home_id", "homeId", "family_id", "familyId", "id")
    if name == target:
        print(f"{home_id}\t{name}")
        raise SystemExit(0)

raise SystemExit(1)
PY
}

active_home_info() {
  home_python active <<'PY'
import json
import sys

path = sys.argv[1]
data = json.load(open(path, "r", encoding="utf-8"))

home_keys = {
    "home_id", "homeId", "home_name", "homeName",
    "family_id", "familyId", "family_name", "familyName",
    "in_use", "inUse",
}

def candidates(value, parent_key=""):
    if isinstance(value, list):
        if value and all(isinstance(item, dict) for item in value):
            parent = parent_key.lower()
            if "home" in parent or "famil" in parent:
                yield value
            elif any(home_keys.intersection(item.keys()) for item in value):
                yield value
        for item in value:
            yield from candidates(item, parent_key)
    elif isinstance(value, dict):
        for key, child in value.items():
            yield from candidates(child, str(key))

def field(item, *names):
    for name in names:
        value = item.get(name)
        if value is not None and str(value) != "":
            return str(value)
    return ""

def truthy(value):
    if isinstance(value, bool):
        return value
    return str(value).lower() in ("1", "true", "yes", "y", "已启用", "当前")

homes = []
for group in candidates(data):
    if len(group) > len(homes):
        homes = group

for item in homes:
    active = item.get("in_use", item.get("inUse", item.get("is_in_use", item.get("current", item.get("selected", False)))))
    if truthy(active):
        name = field(item, "home_name", "homeName", "family_name", "familyName", "name")
        home_id = field(item, "home_id", "homeId", "family_id", "familyId", "id")
        print(f"{home_id}\t{name}")
        raise SystemExit(0)

raise SystemExit(1)
PY
}

current_home_matches_target() {
  local target_id="$1"
  local target_name="$2"
  rm -f "$CURRENT_HOME_CACHE"

  if ! query_home_list; then
    state_mark HOME_CURRENT_DETECT_FAILED
    return 1
  fi

  local active_line active_id active_name
  if ! active_line="$(active_home_info)"; then
    state_mark HOME_CURRENT_DETECT_FAILED
    return 1
  fi
  printf '%s\n' "$active_line" >"$CURRENT_HOME_CACHE"
  IFS=$'\t' read -r active_id active_name <<<"$active_line"

  [[ "$active_name" == "$target_name" ]] && return 0
  [[ -n "$target_id" && "$active_id" == "$target_id" ]] && return 0
  return 1
}

write_target_home_file() {
  local target_id="$1"
  local target_name="$2"
  umask 077
  {
    printf 'XINGUANG_TARGET_HOME=%s\n' "$target_name"
    printf 'XINGUANG_TARGET_HOME_ID=%s\n' "$target_id"
  } >"$TARGET_HOME_FILE"
  chmod 600 "$TARGET_HOME_FILE" 2>/dev/null || true
}

switch_to_target_home() {
  local target_id="$1"
  local target_name="$2"

  [[ -n "$target_id" ]] || die "未找到指定家庭，请检查家庭名称"
  have miloco-cli || die "检测到多个家庭，但当前工具未提供家庭选择能力，请先补充家庭选择功能后再继续。"

  state_mark HOME_SWITCH_STARTED
  if ! timeout 60s miloco-cli scope home switch "$target_id" >"$HOME_SWITCH_RESULT" 2>&1; then
    state_mark HOME_SWITCH_FAILED
    die "家庭切换失败，请检查目标家庭名称后再继续。"
  fi

  if current_home_matches_target "$target_id" "$target_name"; then
    write_target_home_file "$target_id" "$target_name"
    state_mark HOME_SWITCH_DONE
    printf '\n当前家庭已切换为：%s\n' "$target_name"
    return 0
  fi

  state_mark HOME_SWITCH_VERIFY_FAILED
  die "家庭切换后未能确认当前启用家庭，请联系工作人员处理。"
}

check_home_selection_before_install() {
  state_mark HOME_SELECTION_CHECK_START

  if ! have python3; then
    state_mark HOME_SELECTION_REQUIRED
    die "无法确认米家家庭列表，请先补充家庭列表查询和家庭选择功能后再继续。"
  fi

  if ! query_home_list; then
    die "无法查询米家家庭列表，请确认米家账号已绑定后再继续。"
  fi

  local count
  count="$(home_list_count)"
  if [[ -n "$XINGUANG_TARGET_HOME" ]]; then
    local target_line target_id target_name
    if ! target_line="$(target_home_info)"; then
      printf '\n检测到的米家家庭：\n'
      print_home_list
      state_mark TARGET_HOME_NOT_FOUND
      die "未找到指定家庭，请检查家庭名称"
    fi
    IFS=$'\t' read -r target_id target_name <<<"$target_line"
    switch_to_target_home "$target_id" "$target_name"
    return 0
  fi

  if [[ "$count" =~ ^[0-9]+$ ]] && (( count == 1 )); then
    state_mark HOME_SELECTION_SINGLE_HOME_AUTO
    return 0
  fi

  if [[ "$count" =~ ^[0-9]+$ ]] && (( count > 1 )); then
    printf '\n检测到多个米家家庭：\n'
    print_home_list
    printf '\n请指定要控制馨光设备的家庭，例如：XINGUANG_TARGET_HOME="林坞店"\n'
    state_mark HOME_SELECTION_REQUIRED
    die "检测到多个米家家庭，请先选择要控制馨光设备的家庭，不要自动使用第一个家庭。"
  fi

  state_mark HOME_SELECTION_REQUIRED
  die "无法确认米家家庭列表，请先补充家庭列表查询和家庭选择功能后再继续。"
}

summarize_device_list() {
  python3 - "$DEVICE_CACHE" "$DEVICE_REPORT" <<'PY'
import json
import sys

device_path, report_path = sys.argv[1:3]

try:
    raw = json.load(open(device_path, "r", encoding="utf-8"))
except Exception as exc:
    print(f"设备列表解析失败：{exc}")
    raise SystemExit(0)

def walk(value):
    if isinstance(value, dict):
        yield value
        for child in value.values():
            yield from walk(child)
    elif isinstance(value, list):
        for item in value:
            yield from walk(item)

def field(obj, *names):
    for name in names:
        value = obj.get(name)
        if value is not None and str(value) != "":
            return str(value)
    return ""

def online_text(obj):
    for key in ("online", "is_online", "isOnline", "isOnlineDevice", "available"):
        if key in obj:
            value = obj[key]
            if isinstance(value, bool):
                return "在线" if value else "离线"
            lowered = str(value).lower()
            if lowered in ("1", "true", "online", "yes", "在线"):
                return "在线"
            if lowered in ("0", "false", "offline", "no", "离线"):
                return "离线"
    return "未确认"

items = []
seen = set()
for obj in walk(raw):
    if not isinstance(obj, dict):
        continue
    name = field(obj, "name", "device_name", "deviceName", "displayName", "title")
    room = field(obj, "room", "room_name", "roomName", "room_name_cn", "parentRoomName", "area")
    model = field(obj, "model", "modelName", "model_name", "deviceModel", "productModel", "product_model")
    did = field(obj, "did", "id", "device_id", "deviceId", "miotDid")
    if not name and not model and not did:
        continue
    key = did or f"{name}|{room}|{model}|{len(items)}"
    if key in seen:
        continue
    seen.add(key)
    items.append((name or "未命名", room or "未返回", online_text(obj)))

with open(report_path, "w", encoding="utf-8") as handle:
    if not items:
        handle.write("该家庭下暂未读取到设备。\n")
    else:
        for index, (name, room, online) in enumerate(items, 1):
            handle.write(f"{index}. 设备：{name}；房间：{room}；在线状态：{online}\n")

print(f"设备数量：{len(items)}")
PY
}

query_devices() {
  load_env_if_present
  rm -f "$DEVICE_CACHE" "$DEVICE_REPORT"
  state_mark DEVICE_DISCOVERY_STARTED
  if curl -fsS --max-time 20 \
    -H "Authorization: Bearer $WAINFORT_API_TOKEN" \
    "http://127.0.0.1:$WAINFORT_API_PORT/api/devices" \
    -o "$DEVICE_CACHE"; then
    state_mark DEVICE_QUERY_DONE
    state_mark DEVICE_LIST_READY
    if have python3; then
      summarize_device_list || true
    fi
    state_mark DEVICE_DISCOVERY_DONE
    printf '\n已读取当前米家家庭下的设备列表。\n'
    return 0
  fi

  state_mark DEVICE_QUERY_FAILED
  die "暂时无法查询设备，请先确认米家账号已绑定，并且稍后发送“查看馨光 Skill 安装进度”。"
}

check_first_stage_ready() {
  have openclaw || die "请先完成第一阶段安装，再继续安装馨光 Skill。"
  have miloco-cli || die "请先完成第一阶段安装，并确认龙虾相关命令可用。"
  state_mark FIRST_STAGE_READY
}

record_light_result() {
  local api_result="unknown"
  state_mark LIGHT_TEST_SINGLE_SHOT
  state_mark LIGHT_REQUEST_SENT

  case "$LIGHT_API_SUCCESS" in
    false|False|FALSE|0|no|No|NO|failed|Failed|FAILED)
      api_result="false"
      state_mark LIGHT_API_RETURNED_FALSE
      ;;
    true|True|TRUE|1|yes|Yes|YES|ok|OK|success|Success|SUCCESS)
      api_result="true"
      state_mark LIGHT_API_RETURNED_TRUE
      ;;
    *)
      state_mark LIGHT_API_RETURN_UNKNOWN
      ;;
  esac

  if [[ "$LIGHT_TEST_UNSTABLE" == 1 ]]; then
    state_mark UNSTABLE_MULTIPLE_COMMANDS
    printf '测试未通过，请联系工作人员处理。\n'
    return 0
  fi

  case "$LIGHT_PHYSICAL_RESULT" in
    已变化|变化|changed|success|yes|true)
      state_mark PHYSICAL_CHANGED
      if [[ "$api_result" == "false" ]]; then
        state_mark PHYSICAL_SUCCESS_API_FALSE
      fi
      state_mark LIGHT_TEST_SUCCESS
      printf '测试成功。\n'
      printf '\n如果当前效果满意，也可以说：保存当前灯光效果到快照 3。\n'
      ;;
    未变化|没变化|not_changed|failed|no|false)
      state_mark PHYSICAL_NOT_CHANGED
      state_mark LIGHT_TEST_FAILED
      printf '测试未通过，请联系工作人员处理。\n'
      ;;
    多次变化|连续变化|不稳定|unstable|multiple|multiple_commands)
      state_mark UNSTABLE_MULTIPLE_COMMANDS
      printf '测试未通过，请联系工作人员处理。\n'
      ;;
    *)
      state_mark WAITING_PHYSICAL_CONFIRMATION
      state_mark PHYSICAL_CONFIRMATION_REQUIRED
      printf '灯光请求已发送，请观察灯光是否变化。\n'
      printf '如果已变化，请回复：已变化。\n'
      printf '如果未变化，请回复：未变化。\n'
      ;;
  esac
}

print_status() {
  load_env_if_present
  local ready=0
  if { server_status_ok || server_process_running; } &&
    { [[ -f "$LOCAL_SKILL_FILE" ]] || status_file_has SKILL_INSTALL_DONE; }; then
    ready=1
  fi

  if status_file_has HOME_SELECTION_REQUIRED; then
    printf '检测到多个家庭，请选择馨光设备所在家庭：\n\n'
    if [[ -f "$HOME_LIST_CACHE" ]]; then
      print_home_list
    fi
    return 0
  fi
  if status_file_has TARGET_HOME_NOT_FOUND; then
    printf '未找到该家庭，请重新选择。\n'
    return 0
  fi

  if status_file_has PHYSICAL_CHANGED; then
    printf '测试成功。\n'
    printf '\n如果当前效果满意，也可以说：保存当前灯光效果到快照 3。\n'
    return 0
  fi
  if status_file_has PHYSICAL_NOT_CHANGED; then
    printf '测试未通过，请联系工作人员处理。\n'
    return 0
  fi
  if status_file_has LIGHT_TEST_SUCCESS; then
    printf '测试成功。\n'
    printf '\n如果当前效果满意，也可以说：保存当前灯光效果到快照 3。\n'
    return 0
  fi
  if status_file_has LIGHT_TEST_FAILED; then
    printf '测试未通过，请联系工作人员处理。\n'
    return 0
  fi
  if status_file_has LIGHT_REQUEST_SENT; then
    printf '灯光请求已发送，请观察灯光是否变化。\n'
    printf '如果已变化，请回复：已变化。\n'
    printf '如果未变化，请回复：未变化。\n'
    return 0
  fi
  if status_file_has WAINFORT_SERVER_DATA_DIR_UNSUPPORTED || status_file_has WAINFORT_SERVER_START_FAILED; then
    printf '灯光服务暂时无法启动，请联系工作人员处理。\n'
    return 0
  fi

  if (( ready == 1 )); then
    cat <<'EOF'
馨光 Skill 已安装，可以开始测试灯光。

你可以说：
客厅来个马尔代夫的海边日落
EOF
  else
    printf '正在安装馨光 Skill。\n'
  fi
}

main() {
  if [[ "$INSTALL_ACTION" == "status" ]]; then
    print_status
    return 0
  fi
  if [[ "$INSTALL_ACTION" == "preinstall" ]]; then
    printf '%s\n' "$$" >"$PID_FILE"
    printf '正在安装馨光 Skill。\n'
    state_mark "INSTALLER_VERSION=$XINGUANG_SKILL_INSTALLER_VERSION"
    state_mark "SKILL_VERSION=$XINGUANG_SKILL_VERSION"
    state_mark XINGUANG_SKILL_PREINSTALL_STARTED

    check_first_stage_ready
    ensure_env_file
    download_skill
    download_server
    start_server
    install_skill

    state_mark XINGUANG_SKILL_INSTALL_DONE
    state_mark XINGUANG_SKILL_PREINSTALL_DONE
    cat <<'EOF'

馨光 Skill 已安装。
灯光服务已就绪。
EOF
    return 0
  fi
  if [[ "$INSTALL_ACTION" == "record-light-result" || "$INSTALL_ACTION" == "light-result" ]]; then
    record_light_result
    return 0
  fi
  if [[ "$INSTALL_ACTION" != "full" && "$INSTALL_ACTION" != "continue" ]]; then
    die "未知安装动作：$INSTALL_ACTION"
  fi

  printf '%s\n' "$$" >"$PID_FILE"
  printf '正在安装馨光 Skill。\n'
  state_mark "INSTALLER_VERSION=$XINGUANG_SKILL_INSTALLER_VERSION"
  state_mark "SKILL_VERSION=$XINGUANG_SKILL_VERSION"

  check_first_stage_ready
  check_home_selection_before_install
  ensure_env_file
  download_skill
  download_server
  start_server
  install_skill
  query_devices

  state_mark XINGUANG_SKILL_INSTALL_DONE
  cat <<'EOF'

馨光 Skill 已安装。
灯光服务已就绪。
可以开始测试灯光。

你可以说：
客厅来个马尔代夫的海边日落
EOF
}

main "$@"
