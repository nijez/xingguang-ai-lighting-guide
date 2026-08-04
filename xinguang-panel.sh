#!/usr/bin/env bash
set -Eeuo pipefail
set +x

XINGUANG_PANEL_VERSION="1.0.1"
XINGUANG_INSTALL_DIR="$HOME/xinguang-ai-light"
WAINFORT_ENV_FILE="$HOME/wainfort-light/.env"
MILOCO_CONFIG_FILE="$HOME/.openclaw/miloco/config.json"
OPENCLAW_CONFIG_FILE="$HOME/.openclaw/openclaw.json"
SKILL_FILE="$HOME/.openclaw/skills/wainfort-ai-lighting-run/SKILL.md"
SCRIPT_RAW_URL="https://raw.githubusercontent.com/nijez/xingguang-ai-lighting-guide/main/install-miloco-openclaw-cloud.sh"
SKILL_RAW_URL="https://raw.githubusercontent.com/nijez/xingguang-ai-lighting-guide/main/skills/wainfort-ai-lighting-run/SKILL.md"
ENTRY_URL="https://nijez.github.io/xingguang-ai-lighting-guide/install-xinguang-ai-light.sh"
MILOCO_API_URL="http://127.0.0.1:1810"
TEST_PALETTES=(
  '日落|#FF6B5A|#F7C65C'
  '极光|#79D6C7|#A89BEB'
  '海洋|#176B9D|#26B8B5'
)
HEALTH_FIRST_ERROR=""
HEALTH_INSTALL_SCRIPT_OK=1
HEALTH_GATEWAY_OK=1
HEALTH_MIHOME_OK=1
HEALTH_SKILL_OK=1
HEALTH_LIGHT_SERVICE_OK=1
HEALTH_DEVICE_OK=1
HEALTH_DEVICE_OFFLINE_COUNT=0
HEALTH_DEVICE_ONLINE_COUNT=0
HEALTH_DEVICE_UNKNOWN_COUNT=0
HEALTH_DEVICE_EMPTY=0
HEALTH_DEVICE_FETCH_FAILED=0
WAINFORT_API_TOKEN=""
WAINFORT_MILOCO_TOKEN=""
WAINFORT_API_PORT=1888

runtime_command() {
  local command_script
  command_script='
    export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$HOME/.local/share/pnpm:$HOME/.local/share/pnpm/global/5/node_modules/.bin:$PATH"
    for node_bin in "$HOME"/.nvm/versions/node/*/bin; do
      [[ -d "$node_bin" ]] || continue
      export PATH="$node_bin:$PATH"
    done
    "$@"
  '
  if command -v timeout >/dev/null 2>&1; then
    timeout 20s bash -lc "$command_script" bash "$@"
  else
    bash -lc "$command_script" bash "$@"
  fi
}

can_manage_system() {
  command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1
}

require_write_mode() {
  if can_manage_system; then
    return 0
  fi
  printf '当前没有免密管理员权限，面板已降级为只读模式；请联系工作人员处理。\n'
  return 1
}

panel_temp_file() {
  mktemp /tmp/xinguang-panel.XXXXXX
}

extract_script_version() {
  sed -nE 's/^SCRIPT_VERSION="([^"]+)".*/\1/p' "$1" | head -n 1
}

extract_skill_version() {
  sed -nE 's/.*"version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' "$1" | head -n 1
}

installed_script_version() {
  local candidate version
  for candidate in \
    "$XINGUANG_INSTALL_DIR/install-miloco-openclaw-cloud.sh" \
    /tmp/xinguang-light-install.sh \
    /tmp/install-miloco-openclaw-cloud.sh
  do
    [[ -f "$candidate" ]] || continue
    version="$(extract_script_version "$candidate" || true)"
    if [[ -n "$version" ]]; then
      printf '%s\n' "$version"
      return 0
    fi
  done
  return 1
}

online_script_version() {
  local tmp version
  tmp="$(panel_temp_file)"
  version=""
  if curl -fsSL --max-time 5 "$SCRIPT_RAW_URL" -o "$tmp" 2>/dev/null; then
    version="$(extract_script_version "$tmp" || true)"
  fi
  rm -f "$tmp"
  [[ -n "$version" ]] || return 1
  printf '%s\n' "$version"
}

online_skill_version() {
  local tmp version
  tmp="$(panel_temp_file)"
  version=""
  if curl -fsSL --max-time 5 "$SKILL_RAW_URL" -o "$tmp" 2>/dev/null; then
    version="$(extract_skill_version "$tmp" || true)"
  fi
  rm -f "$tmp"
  [[ -n "$version" ]] || return 1
  printf '%s\n' "$version"
}

load_wainfort_env() {
  [[ -r "$WAINFORT_ENV_FILE" ]] || return 1
  WAINFORT_API_TOKEN=""
  WAINFORT_MILOCO_TOKEN=""
  WAINFORT_API_PORT=1888
  set -a
  # shellcheck disable=SC1090
  . "$WAINFORT_ENV_FILE"
  set +a
}

read_miloco_token() {
  [[ -r "$MILOCO_CONFIG_FILE" ]] || return 1
  python3 - "$MILOCO_CONFIG_FILE" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        token = json.load(handle)["server"]["token"]
except (KeyError, OSError, TypeError, json.JSONDecodeError):
    raise SystemExit(1)

if not isinstance(token, str) or not token.strip():
    raise SystemExit(1)
print(token, end="")
PY
}

fetch_devices_json() {
  local target token
  target="$1"
  token="$(read_miloco_token || true)"
  [[ -n "$token" ]] || return 1
  if ! curl -fsS --max-time 12 \
    -H "Authorization: Bearer $token" \
    "$MILOCO_API_URL/api/miot/home" \
    -o "$target" 2>/dev/null; then
    unset token
    return 1
  fi
  unset token
  python3 -m json.tool "$target" >/dev/null 2>&1
}

rgbcwy_rows() {
  python3 - "$1" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        raw = json.load(handle)
except (OSError, json.JSONDecodeError):
    raise SystemExit(1)

def walk(value):
    if isinstance(value, dict):
        yield value
        for child in value.values():
            yield from walk(child)
    elif isinstance(value, list):
        for child in value:
            yield from walk(child)

def field(item, *names):
    for name in names:
        value = item.get(name)
        if value is not None and str(value) != "":
            return str(value)
    return ""

def online(item):
    for key in ("online", "is_online", "isOnline", "available"):
        if key not in item:
            continue
        value = item[key]
        if isinstance(value, bool):
            return "online" if value else "offline"
        if str(value).lower() in ("1", "true", "online", "yes", "在线"):
            return "online"
        if str(value).lower() in ("0", "false", "offline", "no", "离线"):
            return "offline"
    return "unknown"

seen = set()
for item in walk(raw):
    if not isinstance(item, dict):
        continue
    did = field(item, "did", "device_id", "deviceId", "miotDid", "id")
    model = field(item, "model", "modelName", "model_name", "deviceModel")
    if not did or model != "wainft.light.rgbcwy" or did in seen:
        continue
    seen.add(did)
    name = field(item, "name", "device_name", "deviceName", "displayName", "title") or "未命名灯光"
    room = field(item, "room_name", "roomName", "room", "parentRoomName", "area") or "未返回房间"
    print(f"{did}\t{name}\t{room}\t{online(item)}")
PY
}

device_power_state() {
  local did output
  did="$1"
  output="$(runtime_command miloco-cli device props "$did" prop.2.1 2>/dev/null || true)"
  [[ -n "$output" ]] || {
    printf 'unknown\n'
    return 0
  }
  printf '%s' "$output" | python3 -c '
import json
import re
import sys

raw = sys.stdin.read()
values = []

def walk(value):
    if isinstance(value, dict):
        for key, child in value.items():
            if key in ("prop.2.1", "on", "power"):
                yield child
            yield from walk(child)
    elif isinstance(value, list):
        for child in value:
            yield from walk(child)

try:
    values = list(walk(json.loads(raw)))
except json.JSONDecodeError:
    pass

for value in values:
    if isinstance(value, bool):
        print("true" if value else "false")
        raise SystemExit
    lowered = str(value).strip().lower()
    if lowered in ("true", "1", "on", "开启", "已开启"):
        print("true")
        raise SystemExit
    if lowered in ("false", "0", "off", "关闭", "已关闭"):
        print("false")
        raise SystemExit

if re.search(r"(?:prop\.2\.1|on|power)[^\n]{0,80}\btrue\b", raw, re.I):
    print("true")
elif re.search(r"(?:prop\.2\.1|on|power)[^\n]{0,80}\bfalse\b", raw, re.I):
    print("false")
else:
    print("unknown")
' 2>/dev/null || printf 'unknown\n'
}

fetch_homes_json() {
  if ! runtime_command miloco-cli scope home list >"$1" 2>/dev/null; then
    return 1
  fi
  [[ -s "$1" ]] && python3 -m json.tool "$1" >/dev/null 2>&1
}

home_rows() {
  python3 - "$1" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        raw = json.load(handle)
except (OSError, json.JSONDecodeError):
    raise SystemExit(1)

keys = {
    "home_id", "homeId", "home_name", "homeName",
    "family_id", "familyId", "family_name", "familyName",
}

def groups(value, parent_key=""):
    if isinstance(value, list):
        if value and all(isinstance(item, dict) for item in value):
            parent = parent_key.lower()
            if "home" in parent or "famil" in parent or any(keys.intersection(item) for item in value):
                yield value
        for item in value:
            yield from groups(item, parent_key)
    elif isinstance(value, dict):
        for key, child in value.items():
            yield from groups(child, str(key))

def field(item, *names):
    for name in names:
        value = item.get(name)
        if value is not None and str(value) != "":
            return str(value)
    return ""

def truthy(value):
    if isinstance(value, bool):
        return value
    return str(value).lower() in ("1", "true", "yes", "y", "当前", "已启用")

homes = max(list(groups(raw)), key=len, default=[])
for item in homes:
    home_id = field(item, "home_id", "homeId", "family_id", "familyId", "id")
    name = field(item, "home_name", "homeName", "family_name", "familyName", "name") or "未命名家庭"
    active = item.get("in_use", item.get("inUse", item.get("is_in_use", item.get("current", item.get("selected", False)))))
    print(f"{home_id}\t{name}\t{'active' if truthy(active) else 'inactive'}")
PY
}

current_home_name() {
  local home_id home_name active
  while IFS=$'\t' read -r home_id home_name active; do
    if [[ "$active" == active ]]; then
      printf '%s\n' "$home_name"
      return 0
    fi
  done < <(home_rows "$1")
  return 1
}

cron_guard_timer_enabled() {
  command -v systemctl >/dev/null 2>&1 &&
    systemctl is-enabled --quiet xinguang-cron-guard.timer >/dev/null 2>&1
}

cron_guard_timer_active() {
  command -v systemctl >/dev/null 2>&1 &&
    systemctl list-timers --all xinguang-cron-guard.timer 2>/dev/null |
      grep -q 'xinguang-cron-guard.timer' &&
    systemctl is-active --quiet xinguang-cron-guard.timer >/dev/null 2>&1
}

health_error() {
  [[ -n "$HEALTH_FIRST_ERROR" ]] || HEALTH_FIRST_ERROR="$1"
}

check_install_script() {
  local local_version remote_version
  HEALTH_INSTALL_SCRIPT_OK=1
  local_version="$(installed_script_version || true)"
  remote_version="$(online_script_version || true)"
  if [[ -z "$local_version" ]]; then
    printf '❌ 安装脚本      未找到（请执行“更新到最新版”）\n'
    HEALTH_INSTALL_SCRIPT_OK=0
    health_error "请执行“更新到最新版”。"
  elif [[ -z "$remote_version" ]]; then
    printf '⚠️ 安装脚本      %s（无法检查更新）\n' "$local_version"
  elif [[ "$local_version" == "$remote_version" ]]; then
    printf '✅ 安装脚本      %s（最新）\n' "$local_version"
  else
    printf '❌ 安装脚本      %s（可更新到 %s）\n' "$local_version" "$remote_version"
    HEALTH_INSTALL_SCRIPT_OK=0
    health_error "请执行“更新到最新版”。"
  fi
}

check_skill() {
  local local_version remote_version
  HEALTH_SKILL_OK=1
  local_version=""
  [[ -f "$SKILL_FILE" ]] && local_version="$(extract_skill_version "$SKILL_FILE" || true)"
  remote_version="$(online_skill_version || true)"
  if [[ -z "$local_version" ]]; then
    printf '❌ 馨光 Skill    未安装（请在龙虾对话里安装 Skill）\n'
    HEALTH_SKILL_OK=0
    health_error "请在龙虾对话里安装馨光 Skill。"
  elif [[ -z "$remote_version" ]]; then
    printf '⚠️ 馨光 Skill    %s（无法检查更新）\n' "$local_version"
  elif [[ "$local_version" == "$remote_version" ]]; then
    printf '✅ 馨光 Skill    %s（最新）\n' "$local_version"
  else
    printf '❌ 馨光 Skill    %s（可更新到 %s）\n' "$local_version" "$remote_version"
    HEALTH_SKILL_OK=0
    health_error "请在龙虾对话里重新安装馨光 Skill。"
  fi
}

check_gateway() {
  HEALTH_GATEWAY_OK=1
  if command -v systemctl >/dev/null 2>&1 &&
    systemctl --user is-active --quiet openclaw-gateway.service >/dev/null 2>&1; then
    printf '✅ 龙虾网关      运行中\n'
  else
    printf '❌ 龙虾网关      未运行\n'
    HEALTH_GATEWAY_OK=0
    health_error "请先重启龙虾网关。"
  fi
}

check_light_service() {
  local service_ok port_ok
  HEALTH_LIGHT_SERVICE_OK=1
  service_ok=0
  port_ok=0
  if command -v systemctl >/dev/null 2>&1 &&
    systemctl is-active --quiet xinguang-wainfort >/dev/null 2>&1; then
    service_ok=1
  fi
  if command -v ss >/dev/null 2>&1 &&
    ss -ltn 2>/dev/null | grep -Eq ':1888\b'; then
    port_ok=1
  fi
  if (( service_ok && port_ok )); then
    printf '✅ 灯光服务      systemd 托管，运行中\n'
  else
    printf '❌ 灯光服务      未就绪\n'
    HEALTH_LIGHT_SERVICE_OK=0
    health_error "请执行“更新到最新版”后重新检查灯光服务。"
  fi
}

check_mihome_binding() {
  local homes_file rows_file active_home bound
  HEALTH_MIHOME_OK=1
  homes_file="$(panel_temp_file)"
  rows_file="$(panel_temp_file)"
  active_home=""
  bound=0
  if fetch_homes_json "$homes_file"; then
    home_rows "$homes_file" >"$rows_file" 2>/dev/null || true
    [[ -s "$rows_file" ]] && bound=1
    active_home="$(current_home_name "$homes_file" || true)"
  fi
  rm -f "$homes_file" "$rows_file"
  if (( bound )) && [[ -n "$active_home" ]]; then
    printf '✅ 米家账号      已绑定（%s）\n' "$active_home"
  elif (( bound )); then
    printf '✅ 米家账号      已绑定（当前家庭未确认）\n'
  else
    printf '❌ 米家账号      未绑定\n'
    HEALTH_MIHOME_OK=0
    health_error "请在龙虾对话里绑定米家账号并选择家庭。"
  fi
}

check_mimo_key() {
  local status
  status="未配置（省钱模式，正常）"
  if [[ -r "$OPENCLAW_CONFIG_FILE" ]]; then
    status="$(python3 - "$OPENCLAW_CONFIG_FILE" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        value = json.load(handle)["models"]["providers"]["mimo"]["apiKey"]
except (KeyError, OSError, TypeError, json.JSONDecodeError):
    value = ""
print("已配置" if isinstance(value, str) and value.strip() else "未配置（省钱模式，正常）")
PY
)"
  fi
  printf '✅ MiMo Key      %s\n' "$status"
}

check_saving_mode() {
  local cron_list timer_enabled timer_active cron_checked
  cron_list=""
  timer_enabled=0
  timer_active=0
  cron_checked=0

  # 先完成 timer 与 cron 两项同步读取，再统一渲染，避免出现瞬时中间态。
  cron_guard_timer_enabled && timer_enabled=1
  cron_guard_timer_active && timer_active=1
  if cron_list="$(runtime_command openclaw cron list 2>/dev/null)"; then
    cron_checked=1
  fi

  if (( timer_enabled && timer_active && cron_checked )) && ! grep -q 'miloco-' <<<"$cron_list"; then
    printf '✅ 后台省钱      看门狗值守中，模型任务已关\n'
  elif (( timer_enabled && timer_active && cron_checked )); then
    printf '⚠️ 后台省钱      后台模型任务仍在运行，视觉感知可能产生费用\n'
  elif (( timer_enabled && timer_active )); then
    printf '⚠️ 后台省钱      后台任务状态未确认，请稍后重新体检\n'
  elif (( timer_enabled )); then
    printf '⚠️ 后台省钱      定时器未正常运行，请稍后重新体检\n'
  else
    printf '⚠️ 后台省钱      视觉感知已开启，后台模型任务可能产生费用\n'
  fi
}

print_device_list() {
  local devices_file rows_file did name room online power
  HEALTH_DEVICE_OK=1
  HEALTH_DEVICE_OFFLINE_COUNT=0
  HEALTH_DEVICE_ONLINE_COUNT=0
  HEALTH_DEVICE_UNKNOWN_COUNT=0
  HEALTH_DEVICE_EMPTY=0
  HEALTH_DEVICE_FETCH_FAILED=0
  devices_file="$(panel_temp_file)"
  rows_file="$(panel_temp_file)"
  if ! fetch_devices_json "$devices_file"; then
    rm -f "$devices_file" "$rows_file"
    HEALTH_DEVICE_OK=0
    HEALTH_DEVICE_FETCH_FAILED=1
    printf '❌ 设备          暂时无法读取，请检查米家绑定和灯光服务。\n'
    return 1
  fi
  rgbcwy_rows "$devices_file" >"$rows_file" 2>/dev/null || true
  rm -f "$devices_file"
  if [[ ! -s "$rows_file" ]]; then
    rm -f "$rows_file"
    HEALTH_DEVICE_OK=0
    HEALTH_DEVICE_EMPTY=1
    printf '⚠️ 设备          当前家庭未读取到馨光灯。\n'
    return 0
  fi
  while IFS=$'\t' read -r did name room online; do
    case "$online" in
      online)
        HEALTH_DEVICE_ONLINE_COUNT=$((HEALTH_DEVICE_ONLINE_COUNT + 1))
        power="$(device_power_state "$did")"
        case "$power" in
          true) printf '✅ %s（%s）          在线，已开启\n' "$name" "$room" ;;
          false) printf '✅ %s（%s）          在线，已关闭\n' "$name" "$room" ;;
          *) printf '⚠️ %s（%s）          在线，开关未确认\n' "$name" "$room" ;;
        esac
        ;;
      offline)
        HEALTH_DEVICE_OFFLINE_COUNT=$((HEALTH_DEVICE_OFFLINE_COUNT + 1))
        printf '⚠️ %s（%s）          离线（请检查电源）\n' "$name" "$room"
        ;;
      *)
        HEALTH_DEVICE_UNKNOWN_COUNT=$((HEALTH_DEVICE_UNKNOWN_COUNT + 1))
        printf '⚠️ %s（%s）          在线状态未确认\n' "$name" "$room"
        ;;
    esac
  done <"$rows_file"
  rm -f "$rows_file"

  if (( HEALTH_DEVICE_UNKNOWN_COUNT > 0 || HEALTH_DEVICE_ONLINE_COUNT == 0 )); then
    HEALTH_DEVICE_OK=0
  fi
}

health_dependency_conclusion() {
  if (( HEALTH_INSTALL_SCRIPT_OK == 0 )); then
    printf '体检结论：请执行“更新到最新版”。\n'
  elif (( HEALTH_GATEWAY_OK == 0 )); then
    printf '体检结论：请先重启龙虾网关。\n'
  elif (( HEALTH_MIHOME_OK == 0 )); then
    printf '体检结论：请在龙虾对话里绑定米家账号并选择家庭。\n'
  elif (( HEALTH_SKILL_OK == 0 )); then
    printf '体检结论：请在龙虾对话里安装馨光 Skill。\n'
  elif (( HEALTH_LIGHT_SERVICE_OK == 0 )); then
    printf '体检结论：请执行“更新到最新版”后重新检查灯光服务。\n'
  elif (( HEALTH_DEVICE_FETCH_FAILED )); then
    printf '体检结论：请确认米家账号绑定和灯光服务后重新体检。\n'
  elif (( HEALTH_DEVICE_EMPTY )); then
    printf '体检结论：请确认当前家庭已选择并包含馨光灯。\n'
  elif (( HEALTH_DEVICE_UNKNOWN_COUNT > 0 )); then
    printf '体检结论：请检查灯具网络后重新体检。\n'
  elif (( HEALTH_DEVICE_OFFLINE_COUNT > 0 && HEALTH_DEVICE_ONLINE_COUNT == 0 )); then
    printf '体检结论：请检查全部灯具电源后重新体检。\n'
  elif (( HEALTH_DEVICE_OFFLINE_COUNT > 0 )); then
    printf '体检结论：基本正常：%s 盏灯离线（请检查电源），其余可正常使用\n' "$HEALTH_DEVICE_OFFLINE_COUNT"
  else
    printf '体检结论：一切正常，可直接使用。\n'
  fi
}

run_health_check() {
  HEALTH_FIRST_ERROR=""
  printf '\n一键体检\n'
  check_install_script
  check_gateway
  check_mihome_binding
  check_skill
  check_light_service
  if ! print_device_list; then
    HEALTH_DEVICE_OK=0
  fi
  check_mimo_key
  check_saving_mode
  health_dependency_conclusion
}

first_online_on_device() {
  local devices_file rows_file did name room online power
  devices_file="$(panel_temp_file)"
  rows_file="$(panel_temp_file)"
  if ! fetch_devices_json "$devices_file"; then
    rm -f "$devices_file" "$rows_file"
    return 1
  fi
  rgbcwy_rows "$devices_file" >"$rows_file" 2>/dev/null || true
  rm -f "$devices_file"
  while IFS=$'\t' read -r did name room online; do
    [[ "$online" == online ]] || continue
    power="$(device_power_state "$did")"
    if [[ "$power" == true ]]; then
      rm -f "$rows_file"
      printf '%s\t%s\n' "$did" "$name"
      return 0
    fi
  done <"$rows_file"
  rm -f "$rows_file"
  return 1
}

run_light_test() {
  local selected did name color0 color1 palette payload api_port
  selected=""
  require_write_mode || return 0
  if ! selected="$(first_online_on_device)"; then
    printf '当前没有在线且开启的灯，请先开灯。\n'
    return 0
  fi
  IFS=$'\t' read -r did name <<<"$selected"
  palette="${TEST_PALETTES[RANDOM % ${#TEST_PALETTES[@]}]}"
  IFS='|' read -r _ color0 color1 <<<"$palette"
  if ! load_wainfort_env || [[ -z "$WAINFORT_API_TOKEN" ]]; then
    printf '灯光服务配置暂时无法读取，请联系工作人员处理。\n'
    return 0
  fi
  api_port="$WAINFORT_API_PORT"
  payload="$(python3 - "$did" "$color0" "$color1" <<'PY'
import json
import sys
print(json.dumps({
    "did": sys.argv[1],
    "color0": sys.argv[2],
    "color1": sys.argv[3],
    "brightness": 100,
}, ensure_ascii=False))
PY
)"
  printf '正在向 %s 发送测试效果。\n' "$name"
  if curl -fsS --max-time 20 -X POST "http://127.0.0.1:$api_port/api/generate" \
    -H "Authorization: Bearer $WAINFORT_API_TOKEN" \
    -H 'Content-Type: application/json' \
    -d "$payload" >/dev/null 2>&1 &&
    [[ "$(device_power_state "$did")" == true ]]; then
    unset WAINFORT_API_TOKEN WAINFORT_MILOCO_TOKEN
    printf '测试效果已发送到 %s，请观察灯光变化\n' "$name"
  else
    unset WAINFORT_API_TOKEN WAINFORT_MILOCO_TOKEN
    printf '灯光测试暂时未完成，请稍后再试。\n'
  fi
}

show_devices() {
  printf '\n我的设备\n'
  print_device_list || true
}

switch_home() {
  local homes_file rows_file verify_file count index home_id home_name active choice selected verified_home
  require_write_mode || return 0
  homes_file="$(panel_temp_file)"
  rows_file="$(panel_temp_file)"
  if ! fetch_homes_json "$homes_file"; then
    rm -f "$homes_file" "$rows_file"
    printf '家庭列表暂时无法读取，请先确认米家账号已绑定。\n'
    return 0
  fi
  home_rows "$homes_file" >"$rows_file" 2>/dev/null || true
  rm -f "$homes_file"
  count="$(awk 'END { print NR }' "$rows_file")"
  if [[ "$count" == 0 ]]; then
    rm -f "$rows_file"
    printf '当前没有可切换的家庭，请先确认米家账号已绑定。\n'
    return 0
  fi
  printf '\n切换家庭\n'
  index=0
  while IFS=$'\t' read -r home_id home_name active; do
    index=$(( index + 1 ))
    if [[ "$active" == active ]]; then
      printf '%d. %s（当前使用）\n' "$index" "$home_name"
    else
      printf '%d. %s\n' "$index" "$home_name"
    fi
  done <"$rows_file"
  printf '请输入序号：'
  IFS= read -r choice || choice=""
  if [[ ! "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > count )); then
    rm -f "$rows_file"
    printf '未选择家庭，已返回。\n'
    return 0
  fi
  selected="$(awk -v number="$choice" 'NR == number { print; exit }' "$rows_file")"
  rm -f "$rows_file"
  IFS=$'\t' read -r home_id home_name active <<<"$selected"
  printf '正在切换家庭。\n'
  verified_home=""
  verify_file="$(panel_temp_file)"
  if runtime_command miloco-cli scope home switch "$home_id" >/dev/null 2>&1 &&
    runtime_command xinguang-set-home "$home_name" "$home_id" >/dev/null 2>&1 &&
    fetch_homes_json "$verify_file"; then
    verified_home="$(current_home_name "$verify_file" || true)"
  fi
  rm -f "$verify_file"
  if [[ "$verified_home" == "$home_name" ]]; then
    printf '已切换为：%s\n' "$home_name"
    printf '无需重新安装 Skill，直接可用。\n'
  else
    printf '家庭切换暂时未完成，请稍后再试。\n'
  fi
}

update_to_latest() {
  local entry_file update_status
  require_write_mode || return 0
  entry_file="$(panel_temp_file)"
  update_status=0
  printf '正在更新到最新版，请稍候。\n'
  if ! curl -fsSL --max-time 30 "$ENTRY_URL" -o "$entry_file" 2>/dev/null; then
    rm -f "$entry_file"
    printf '更新文件暂时无法下载，请稍后再试。\n'
    return 0
  fi
  bash "$entry_file" || update_status=1
  rm -f "$entry_file"
  if (( update_status == 0 )); then
    printf '已完成更新。\n'
    printf '请在龙虾对话里新开一个会话以生效\n'
  else
    printf '更新暂时未完成，请稍后再试。\n'
  fi
}

current_chat_model() {
  [[ -r "$OPENCLAW_CONFIG_FILE" ]] || return 1
  python3 - "$OPENCLAW_CONFIG_FILE" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        model = json.load(handle)["agents"]["defaults"]["model"]["primary"]
except (KeyError, OSError, TypeError, json.JSONDecodeError):
    raise SystemExit(1)
if isinstance(model, str) and model.strip():
    print(model)
else:
    raise SystemExit(1)
PY
}

manage_chat_model() {
  local model key choice
  model="$(current_chat_model || true)"
  printf '\n对话模型\n'
  printf '当前模型：%s\n' "$model"
  printf '1. 切换 DeepSeek\n'
  printf '0. 返回\n'
  printf '请输入序号：'
  IFS= read -r choice || choice=0
  [[ "$choice" == 1 ]] || return 0
  require_write_mode || return 0
  printf '请输入 DeepSeek Key：'
  IFS= read -r -s key || key=""
  printf '\n'
  if [[ -z "$key" ]]; then
    printf '未输入 Key，未修改对话模型。\n'
    return 0
  fi
  if runtime_command xinguang-set-chat-model deepseek "$key" >/dev/null 2>&1; then
    unset key
    printf '已切换为 DeepSeek。\n'
    printf '请在龙虾对话里新开一个会话以生效\n'
  else
    unset key
    printf '对话模型切换暂时未完成，请稍后再试。\n'
  fi
}

ensure_cron_guard_units() {
  local guard_script service_tmp timer_tmp runtime_user
  guard_script="$XINGUANG_INSTALL_DIR/xinguang-cron-guard"
  [[ -x "$guard_script" ]] || {
    printf '未找到后台省钱服务，请先更新到最新版。\n'
    return 1
  }
  if sudo test -f /etc/systemd/system/xinguang-cron-guard.service &&
    sudo test -f /etc/systemd/system/xinguang-cron-guard.timer; then
    return 0
  fi
  service_tmp="$(mktemp /tmp/xinguang-cron-guard.service.XXXXXX)"
  timer_tmp="$(mktemp /tmp/xinguang-cron-guard.timer.XXXXXX)"
  runtime_user="$(id -un)"
  cat >"$service_tmp" <<EOF
[Unit]
Description=馨光后台省钱服务

[Service]
Type=oneshot
User=$runtime_user
ExecStart=/bin/bash -lc '$guard_script'
EOF
  cat >"$timer_tmp" <<'EOF'
[Unit]
Description=馨光后台省钱定时器

[Timer]
OnBootSec=2min
OnUnitActiveSec=10min
Persistent=true
Unit=xinguang-cron-guard.service

[Install]
WantedBy=timers.target
EOF
  if sudo install -m 0644 "$service_tmp" /etc/systemd/system/xinguang-cron-guard.service &&
    sudo install -m 0644 "$timer_tmp" /etc/systemd/system/xinguang-cron-guard.timer &&
    sudo systemctl daemon-reload >/dev/null 2>&1; then
    rm -f "$service_tmp" "$timer_tmp"
    return 0
  fi
  rm -f "$service_tmp" "$timer_tmp"
  return 1
}

show_sensing_state() {
  if cron_guard_timer_enabled; then
    printf '当前状态：视觉感知已关闭，后台省钱正在值守。\n'
  else
    printf '当前状态：视觉感知已开启。\n'
  fi
  printf '费用说明：开启后 Miloco 将持续调用大模型，产生费用\n'
}

enable_sensing() {
  require_write_mode || return 0
  printf '正在开启视觉感知。\n'
  if sudo systemctl disable --now xinguang-cron-guard.timer >/dev/null 2>&1 &&
    runtime_command openclaw gateway restart >/dev/null 2>&1 &&
    ! cron_guard_timer_enabled; then
    printf '视觉感知已开启。\n'
    printf '如需感知功能请在腾讯云控制台配置 MiMo Key\n'
  else
    printf '视觉感知暂时未开启，请稍后再试。\n'
  fi
}

disable_sensing() {
  require_write_mode || return 0
  printf '正在关闭视觉感知，进入后台省钱模式。\n'
  if ensure_cron_guard_units &&
    sudo systemctl enable --now xinguang-cron-guard.timer >/dev/null 2>&1 &&
    bash "$XINGUANG_INSTALL_DIR/xinguang-cron-guard" >/dev/null 2>&1 &&
    cron_guard_timer_enabled; then
    printf '已关闭视觉感知，后台省钱正在值守。\n'
  else
    printf '后台省钱暂时未开启，请稍后再试。\n'
  fi
}

manage_sensing() {
  local choice
  printf '\n视觉感知开关\n'
  show_sensing_state
  printf '1. 开启视觉感知\n'
  printf '2. 关闭视觉感知\n'
  printf '0. 返回\n'
  printf '请输入序号：'
  IFS= read -r choice || choice=0
  case "$choice" in
    1) enable_sensing ;;
    2) disable_sensing ;;
    *) return 0 ;;
  esac
}

# 覆盖 sk-、wainfort-ai-、"(api_?key|token|key)"、长 base64 与 JWT/授权码五类敏感串。
sanitize_stream() {
  sed -E \
    -e 's/sk-[A-Za-z0-9]{8,}/[已脱敏]/g' \
    -e 's/wainfort-ai-[0-9a-z-]{8,}/[已脱敏]/g' \
    -e 's/"([aA][pP][iI]_?[kK][eE][yY]|[tT][oO][kK][eE][nN]|[kK][eE][yY])"[[:space:]]*[:=][[:space:]]*"[^"]+"/[已脱敏]/g' \
    -e 's/eyJ[A-Za-z0-9+/=]{20,}/[已脱敏]/g' \
    -e 's/[A-Za-z0-9+/]{40,}={0,2}/[已脱敏]/g'
}

sanitize_file() {
  [[ -f "$1" ]] || return 0
  sanitize_stream <"$1" >"$2"
}

collect_diagnostic_package() {
  local bundle_dir archive source target script_version skill_version diagnostic_tmp_dir
  diagnostic_tmp_dir="${XINGUANG_DIAGNOSTIC_TMP_DIR:-/tmp}"
  bundle_dir="$(mktemp -d "$diagnostic_tmp_dir/xinguang-diagnosis.XXXXXX")"
  archive="$diagnostic_tmp_dir/xinguang-诊断-$(date +%Y%m%d-%H%M).tar.gz"
  mkdir -p "$bundle_dir/状态文件" "$bundle_dir/日志"
  printf '正在收集诊断信息。\n'
  run_health_check 2>&1 | sanitize_stream >"$bundle_dir/体检输出.txt" || true
  script_version="$(installed_script_version || true)"
  skill_version="$(extract_skill_version "$SKILL_FILE" 2>/dev/null || true)"
  {
    printf '维护面板版本：%s\n' "$XINGUANG_PANEL_VERSION"
    printf '安装脚本版本：%s\n' "$script_version"
    printf '馨光 Skill 版本：%s\n' "$skill_version"
  } | sanitize_stream >"$bundle_dir/版本清单.txt"
  for source in "$diagnostic_tmp_dir"/xinguang-*.state; do
    [[ -f "$source" ]] || continue
    target="$bundle_dir/状态文件/$(basename "$source")"
    sanitize_file "$source" "$target"
  done
  for source in "$HOME"/wainfort-light/*.log; do
    [[ -f "$source" ]] || continue
    target="$bundle_dir/日志/$(basename "$source")"
    tail -n 200 "$source" | sanitize_stream >"$target"
  done
  if [[ -f "$HOME/miloco-cloud-install.log" ]]; then
    tail -n 200 "$HOME/miloco-cloud-install.log" |
      sanitize_stream >"$bundle_dir/日志/miloco-cloud-install.log"
  fi
  print_device_list 2>&1 | sanitize_stream >"$bundle_dir/设备清单.txt" || true
  if tar -czf "$archive" -C "$bundle_dir" .; then
    rm -rf "$bundle_dir"
    printf '诊断包已导出：%s\n' "$archive"
    printf '请把此文件发给工作人员\n'
  else
    rm -rf "$bundle_dir"
    printf '诊断包暂时未导出，请稍后再试。\n'
  fi
}

run_redaction_stream_demo() {
  local sample sanitized remaining
  sample="$(panel_temp_file)"
  {
    printf '%s\n' 'sk-1234567890abcdef'
    printf '%s\n' 'wainfort-ai-12345678-abcd'
    printf '%s\n' '"apiKey":"demo-value"'
    printf '%s\n' 'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ4aW5ndWFuZyJ9'
    printf '%s\n' 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/ABCD'
  } >"$sample"
  sanitized="$(sanitize_stream <"$sample")"
  rm -f "$sample"
  remaining=0
  if printf '%s\n' "$sanitized" |
    grep -Eq 'sk-[A-Za-z0-9]{8,}|wainfort-ai-[0-9a-z-]{8,}|eyJ[A-Za-z0-9+/=]{20,}|[A-Za-z0-9+/]{40,}={0,2}|demo-value'; then
    remaining=1
  fi
  printf '脱敏演示：grep 剩余匹配数为 %s\n' "$remaining"
  (( remaining == 0 ))
}

run_diagnostic_redaction_demo() {
  local test_root test_home test_tmp test_bin archive unpack remaining status
  local original_path
  test_root="$(mktemp -d /tmp/xinguang-panel-redaction.XXXXXX)"
  test_home="$test_root/home"
  test_tmp="$test_root/tmp"
  test_bin="$test_home/.local/bin"
  original_path="$PATH"
  status=0
  mkdir -p "$test_bin" "$test_tmp" \
    "$test_home/.openclaw/miloco" \
    "$test_home/.openclaw/skills/wainfort-ai-lighting-run" \
    "$test_home/wainfort-light"

  cat >"$test_bin/curl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
target=""
url=""
while (( $# > 0 )); do
  case "$1" in
    -o)
      target="$2"
      shift 2
      ;;
    http://*|https://*)
      url="$1"
      shift
      ;;
    *)
      shift
      ;;
  esac
done
if [[ "$url" == *"/api/miot/home" ]]; then
  payload='{"data":[{"did":"demo-device","model":"wainft.light.rgbcwy","name":"sk-1234567890abcdef","room_name":"eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ4aW5ndWFuZyJ9","online":true}]}'
elif [[ "$url" == *"SKILL.md" ]]; then
  payload='metadata: {"openclaw":{"version":"4.0.7"}}'
else
  payload='SCRIPT_VERSION="2026-06-25.44"'
fi
if [[ -n "$target" ]]; then
  printf '%s\n' "$payload" >"$target"
else
  printf '%s\n' "$payload"
fi
EOF
  cat >"$test_bin/miloco-cli" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ "$1" == scope && "$2" == home && "$3" == list ]]; then
  printf '%s\n' '{"data":[{"home_id":"demo-home","home_name":"演示家庭","in_use":true}]}'
elif [[ "$1" == device && "$2" == props ]]; then
  printf '%s\n' '{"prop.2.1":true}'
fi
EOF
  chmod +x "$test_bin/curl" "$test_bin/miloco-cli"

  HOME="$test_home"
  export HOME
  PATH="$test_bin:$original_path"
  export PATH
  XINGUANG_INSTALL_DIR="$HOME/xinguang-ai-light"
  WAINFORT_ENV_FILE="$HOME/wainfort-light/.env"
  MILOCO_CONFIG_FILE="$HOME/.openclaw/miloco/config.json"
  OPENCLAW_CONFIG_FILE="$HOME/.openclaw/openclaw.json"
  SKILL_FILE="$HOME/.openclaw/skills/wainfort-ai-lighting-run/SKILL.md"
  XINGUANG_DIAGNOSTIC_TMP_DIR="$test_tmp"
  export XINGUANG_DIAGNOSTIC_TMP_DIR
  printf '%s\n' '{"server":{"token":"demo-token"}}' >"$MILOCO_CONFIG_FILE"
  printf '%s\n' 'metadata: {"openclaw":{"version":"4.0.7"}}' >"$SKILL_FILE"
  {
    printf '%s\n' 'sk-1234567890abcdef'
    printf '%s\n' 'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ4aW5ndWFuZyJ9'
    printf '%s\n' 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/ABCD'
    printf '%s\n' '"api_key":"demo-value"'
  } >"$test_tmp/xinguang-redaction-demo.state"
  cp "$test_tmp/xinguang-redaction-demo.state" "$test_home/wainfort-light/demo.log"
  cp "$test_tmp/xinguang-redaction-demo.state" "$test_home/miloco-cloud-install.log"

  collect_diagnostic_package >"$test_root/diagnostic-output.txt" 2>&1 || status=1
  archive="$(find "$test_tmp" -maxdepth 1 -type f -name 'xinguang-诊断-*.tar.gz' -print -quit)"
  if [[ -z "$archive" ]]; then
    status=1
    remaining=1
  else
    unpack="$test_root/unpack"
    mkdir -p "$unpack"
    if ! tar -xzf "$archive" -C "$unpack"; then
      status=1
    fi
    remaining="$({ grep -R -E -o 'sk-[A-Za-z0-9]{8,}|eyJ[A-Za-z0-9+/=]{20,}|[A-Za-z0-9+/]{40,}={0,2}|demo-value' "$unpack" 2>/dev/null || true; } | wc -l | tr -d ' ')"
  fi
  printf '完整诊断脱敏演示：解包 grep 剩余匹配数为 %s\n' "$remaining"
  rm -rf "$test_root"
  (( status == 0 && remaining == 0 ))
}

run_redaction_demo() {
  run_redaction_stream_demo &&
    run_diagnostic_redaction_demo
}

print_menu() {
  printf '\n========================================\n'
  printf '  馨光 AI 灯光 · 维护面板  v%s\n' "$XINGUANG_PANEL_VERSION"
  printf '========================================\n'
  printf '  1. 一键体检          （查所有组件，红绿灯结论）\n'
  printf '  2. 灯光测试          （随机效果打到一盏在线灯，眼见为实）\n'
  printf '  3. 我的设备          （馨光灯清单：房间/在线/开关）\n'
  printf '  4. 切换家庭          （多家庭时更换馨光设备所在家庭）\n'
  printf '  5. 更新到最新版      （等于重跑一键安装，全自动）\n'
  printf '  ----------------------------------------\n'
  printf '  6. 对话模型          （查看当前模型 / 切换 DeepSeek）\n'
  printf '  7. 视觉感知开关      （开启=Miloco后台任务+需MiMo Key；关闭=省钱模式）\n'
  printf '  ----------------------------------------\n'
  printf '  8. 导出诊断包        （发给工作人员用，已自动脱敏）\n'
  printf '  0. 退出\n'
  printf '请输入序号：'
}

main() {
  local choice
  if ! can_manage_system; then
    printf '当前没有免密管理员权限，面板已降级为只读模式。\n'
  fi
  while true; do
    print_menu
    IFS= read -r choice || choice=0
    case "$choice" in
      1) run_health_check || true ;;
      2) run_light_test || true ;;
      3) show_devices || true ;;
      4) switch_home || true ;;
      5) update_to_latest || true ;;
      6) manage_chat_model || true ;;
      7) manage_sensing || true ;;
      8) collect_diagnostic_package || true ;;
      0)
        printf '已退出维护面板。\n'
        return 0
        ;;
      *) printf '请输入 0 到 8 之间的序号。\n' ;;
    esac
  done
}

ACTION=""
if (( $# > 0 )); then
  ACTION="$1"
fi
case "$ACTION" in
  --self-test-redaction) run_redaction_demo ;;
  --version) printf '%s\n' "$XINGUANG_PANEL_VERSION" ;;
  *) main ;;
esac
