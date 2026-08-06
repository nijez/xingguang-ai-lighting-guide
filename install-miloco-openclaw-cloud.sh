#!/usr/bin/env bash
set -Eeuo pipefail

# One-shot OpenClaw + Xiaomi Miloco installer for a Tencent Cloud OpenClaw app-template VM.
# Defaults are intentionally conservative:
# - OpenClaw gateway binds to loopback only.
# - Mi Home account binding is skipped.
# - WeChat channel installation/login is skipped.
# - MiMo API key is synchronized from explicit input or OpenClaw configuration.

SCRIPT_VERSION="2026-06-25.47"
TOTAL_STEPS=6
MILOCO_VERSION="${MILOCO_VERSION:-2026.6.18}"
OPENCLAW_PORT="${OPENCLAW_PORT:-18789}"
OPENCLAW_BIND="${OPENCLAW_BIND:-loopback}"
OPENCLAW_MIN_VERSION="${OPENCLAW_MIN_VERSION:-2026.6.10}"
RUN_SYSTEM_UPGRADE="${RUN_SYSTEM_UPGRADE:-0}"
OPENCLAW_UPDATE="${OPENCLAW_UPDATE:-auto}"
INSTALL_EXTRA_PLUGINS="${INSTALL_EXTRA_PLUGINS:-0}"
INSTALL_ACTION="${INSTALL_ACTION:-}"
INSTALL_NONINTERACTIVE="${INSTALL_NONINTERACTIVE:-0}"
RUN_CONTEXT="${RUN_CONTEXT:-}"
DEPLOY_SUPERVISOR="${DEPLOY_SUPERVISOR:-0}"
SUPERVISOR_UNIT="${SUPERVISOR_UNIT:-xingguang-miloco-deploy}"
PID_FILE="${PID_FILE:-/tmp/openclaw-miloco-install.pid}"
PRELOAD_MILOCO_BUNDLE="${PRELOAD_MILOCO_BUNDLE:-1}"
CACHE_MILOCO_BUNDLE="${CACHE_MILOCO_BUNDLE:-1}"
INSTALL_WEIXIN_PLUGIN="${INSTALL_WEIXIN_PLUGIN:-0}"
DOWNLOAD_TIMEOUT="${DOWNLOAD_TIMEOUT:-900}"
OPENCLAW_UPGRADE_EXPECTED_BYTES="${OPENCLAW_UPGRADE_EXPECTED_BYTES:-0}"
MIRROR_TEST_TIMEOUT="${MIRROR_TEST_TIMEOUT:-8}"
MIRROR_TEST_RANGE="${MIRROR_TEST_RANGE:-0-1048575}"
AUTO_SELECT_MIRRORS="${AUTO_SELECT_MIRRORS:-1}"
MILOCO_HOME="${MILOCO_HOME:-$HOME/.openclaw/miloco}"
MILOCO_CLOUD_CACHE="${MILOCO_CLOUD_CACHE:-$HOME/.cache/miloco-cloud-installer}"
MILOCO_INSTALLER_URLS="${MILOCO_INSTALLER_URLS:-}"
MILOCO_BUNDLE_URLS="${MILOCO_BUNDLE_URLS:-}"
MILOCO_WHEELHOUSE_URL="${MILOCO_WHEELHOUSE_URL:-}"
PYPI_INDEX="${PYPI_INDEX:-auto}"
PYPI_FALLBACK_OFFICIAL="${PYPI_FALLBACK_OFFICIAL:-1}"
NPM_REGISTRY="${NPM_REGISTRY:-auto}"
MIMO_API_KEY="${MIMO_API_KEY:-}"
DEEPSEEK_API_KEY="${DEEPSEEK_API_KEY:-}"
XINGUANG_KEEP_MILOCO_CRON="${XINGUANG_KEEP_MILOCO_CRON-}"
LOG_FILE="${LOG_FILE:-$HOME/miloco-cloud-install.log}"
STATE_FILE="${STATE_FILE:-/tmp/xinguang-light-install.state}"
XINGUANG_SKILL_ENTRY_VERSION="${XINGUANG_SKILL_ENTRY_VERSION:-2026-06-26.19}"
XINGUANG_SKILL_INSTALLER_VERSION="${XINGUANG_SKILL_INSTALLER_VERSION:-2026-06-26.19}"
XINGUANG_PANEL_VERSION="1.0.1"
XINGUANG_SHOW_VERSION="1.0.0"
XINGUANG_LOCAL_INSTALL_DIR="${XINGUANG_LOCAL_INSTALL_DIR:-$HOME/xinguang-ai-light}"

absolute_path() {
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    *) printf '%s/%s\n' "$PWD" "$1" ;;
  esac
}

STATE_FILE="$(absolute_path "$STATE_FILE")"

exec 3>&1
mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1
SCRIPT_START_EPOCH="$(date +%s)"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/miloco-cloud-install.XXXXXX")"
WHEELHOUSE_DIR=""
UV_WRAPPER_DIR=""

cleanup() {
  rm -rf "$WORK_DIR"
  if [[ -n "$UV_WRAPPER_DIR" ]]; then
    rm -rf "$UV_WRAPPER_DIR"
  fi
}
trap cleanup EXIT

log() {
  printf '\n[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2
}

state_init() {
  mkdir -p "$(dirname "$STATE_FILE")"
  touch "$STATE_FILE"
}

state_has() {
  local marker="$1"
  [[ -f "$STATE_FILE" ]] && grep -Fxq "$marker" "$STATE_FILE"
}

install_complete_state() {
  state_has STEP_6_DONE || state_has SUCCESS_ACTIVE || state_has SUCCESS_AFTER_RECONNECT
}

state_mark() {
  local marker="$1"
  state_init
  grep -Fxq "$marker" "$STATE_FILE" || printf '%s\n' "$marker" >>"$STATE_FILE"
  printf 'STATE: %s\n' "$marker" >&2
}

state_mark_silent() {
  local marker="$1"
  state_init
  grep -Fxq "$marker" "$STATE_FILE" || printf '%s\n' "$marker" >>"$STATE_FILE"
}

state_last_done() {
  if [[ ! -f "$STATE_FILE" ]]; then
    printf 'none'
    return
  fi
  grep -E '^STEP_[0-9]+_DONE$' "$STATE_FILE" | tail -n 1 || printf 'none'
}

state_next_step() {
  local i
  for i in 1 2 3 4 5 6; do
    if ! state_has "STEP_${i}_DONE"; then
      printf 'STEP_%s' "$i"
      return
    fi
  done
  printf 'COMPLETE'
}

recommended_continue_command() {
  printf 'INSTALL_ACTION=continue RUN_SYSTEM_UPGRADE=0 OPENCLAW_UPDATE=auto INSTALL_EXTRA_PLUGINS=0 INSTALL_NONINTERACTIVE=1 bash /tmp/install-miloco-openclaw-cloud.sh'
}

print_incomplete_report() {
  local reason="${1:-unknown}"
  if install_complete_state; then
    return 0
  fi
  state_mark EXITED_BUT_INCOMPLETE || true
  cat >&2 <<EOF

安装未完成，请联系工作人员处理。
EOF
}

step_start_msg() {
  local number="$1"
  local title="$2"
  if [[ "$TOTAL_STEPS" == 6 ]]; then
    state_mark_silent "STEP_${number}_STARTED"
  fi
  printf '\n[%s] Step %s/%s: %s\n' "$(date +%H:%M:%S)" "$number" "$TOTAL_STEPS" "$title" >&2
}

step_done_msg() {
  local number="$1"
  local title="$2"
  local start_epoch="$3"
  local elapsed
  elapsed="$(($(date +%s) - start_epoch))"
  printf '[%s] ✓ Step %s/%s done: %s (%s)\n' "$(date +%H:%M:%S)" "$number" "$TOTAL_STEPS" "$title" "$(format_duration "$elapsed")" >&2
  if [[ "$TOTAL_STEPS" == 6 ]]; then
    state_mark "STEP_${number}_DONE"
  fi
}

step_skip_msg() {
  local number="$1"
  local title="$2"
  local reason="$3"
  printf '[%s] - Step %s/%s skipped: %s (%s)\n' "$(date +%H:%M:%S)" "$number" "$TOTAL_STEPS" "$title" "$reason" >&2
}

format_duration() {
  local seconds="$1"
  printf '%02d:%02d:%02d' "$((seconds / 3600))" "$(((seconds % 3600) / 60))" "$((seconds % 60))"
}

log_timing_since() {
  local label="$1"
  local start_epoch="$2"
  local end_epoch elapsed
  end_epoch="$(date +%s)"
  elapsed="$((end_epoch - start_epoch))"
  log "Timing: $label took $(format_duration "$elapsed") (${elapsed}s)"
}

script_path() {
  readlink -f "$0" 2>/dev/null || printf '%s' "$0"
}

write_supervisor_launcher() {
  local launcher="$1"
  local script
  script="$(script_path)"

  {
    printf '#!/usr/bin/env bash\n'
    printf 'set -Eeuo pipefail\n'
    printf 'echo $$ > %q\n' "$PID_FILE"
    printf 'export DEPLOY_SUPERVISOR=0\n'
    if [[ "${RUN_CONTEXT:-}" == terminal* ]]; then
      printf 'export RUN_CONTEXT=terminal_supervisor\n'
    else
      printf 'export RUN_CONTEXT=agentchat_supervisor\n'
    fi
    printf 'export INSTALL_ACTION=%q\n' "${INSTALL_ACTION:-full}"
    printf 'export RUN_SYSTEM_UPGRADE=%q\n' "$RUN_SYSTEM_UPGRADE"
    printf 'export OPENCLAW_UPDATE=%q\n' "$OPENCLAW_UPDATE"
    printf 'export INSTALL_EXTRA_PLUGINS=%q\n' "$INSTALL_EXTRA_PLUGINS"
    printf 'export INSTALL_NONINTERACTIVE=%q\n' "$INSTALL_NONINTERACTIVE"
    printf 'export LOG_FILE=%q\n' "$LOG_FILE"
    printf 'export STATE_FILE=%q\n' "$STATE_FILE"
    printf 'export PID_FILE=%q\n' "$PID_FILE"
    printf 'export MILOCO_VERSION=%q\n' "$MILOCO_VERSION"
    printf 'export OPENCLAW_PORT=%q\n' "$OPENCLAW_PORT"
    printf 'export OPENCLAW_BIND=%q\n' "$OPENCLAW_BIND"
    printf 'export OPENCLAW_MIN_VERSION=%q\n' "$OPENCLAW_MIN_VERSION"
    printf 'export INSTALL_WEIXIN_PLUGIN=%q\n' "$INSTALL_WEIXIN_PLUGIN"
    printf 'export XINGUANG_KEEP_MILOCO_CRON=%q\n' "$XINGUANG_KEEP_MILOCO_CRON"
    printf 'export XINGUANG_SKILL_ENTRY_VERSION=%q\n' "$XINGUANG_SKILL_ENTRY_VERSION"
    printf 'export XINGUANG_SKILL_INSTALLER_VERSION=%q\n' "$XINGUANG_SKILL_INSTALLER_VERSION"
    printf 'export XINGUANG_LOCAL_INSTALL_DIR=%q\n' "$XINGUANG_LOCAL_INSTALL_DIR"
    printf 'exec bash %q\n' "$script"
  } >"$launcher"
  chmod +x "$launcher"
}

format_elapsed_mmss() {
  local seconds="${1:-0}"
  printf '%02d:%02d' $((seconds / 60)) $((seconds % 60))
}

format_megabytes() {
  local bytes="${1:-0}"
  [[ "$bytes" =~ ^[0-9]+$ ]] || bytes=0
  LC_ALL=C awk -v bytes="$bytes" 'BEGIN { printf "%.1f", bytes / 1048576 }'
}

format_download_speed_kbps() {
  local bytes="${1:-0}" seconds="${2:-0}"
  [[ "$bytes" =~ ^[0-9]+$ ]] || bytes=0
  [[ "$seconds" =~ ^[0-9]+$ ]] || seconds=0
  LC_ALL=C awk -v bytes="$bytes" -v seconds="$seconds" 'BEGIN {
    if (seconds <= 0) {
      printf "0.0"
    } else {
      printf "%.1f", bytes / seconds / 1024
    }
  }'
}

downloaded_file_size() {
  [[ -f "$1" ]] || {
    printf '0\n'
    return 0
  }
  wc -c <"$1" 2>/dev/null | tr -d '[:space:]'
}

curl_progress_percent() {
  [[ -s "$1" ]] || return 1
  LC_ALL=C tr '\r' '\n' <"$1" |
    grep -oE '[0-9]{1,3}([.][0-9]+)?%' |
    tail -n 1 |
    sed -E 's/[^0-9].*//'
}

download_remaining_minutes() {
  local downloaded="$1" total="$2" elapsed="$3" remaining_seconds
  if (( downloaded <= 0 || total <= downloaded || elapsed <= 0 )); then
    printf '0\n'
    return 0
  fi
  remaining_seconds=$(((total - downloaded) * elapsed / downloaded))
  printf '%s\n' "$(((remaining_seconds + 59) / 60))"
}

state_update_download_progress() {
  local label="$1" percent="$2" downloaded="$3" total="$4" remaining="$5" elapsed="$6"
  local state_tmp
  state_init
  state_tmp="$(mktemp "$(dirname "$STATE_FILE")/.xinguang-download.XXXXXX")"
  {
    grep -v '^DOWNLOAD_PROGRESS|' "$STATE_FILE" 2>/dev/null || true
    printf 'DOWNLOAD_PROGRESS|%s|%s|%s|%s|%s|%s\n' \
      "$label" "$percent" "$downloaded" "$total" "$remaining" "$elapsed"
  } >"$state_tmp"
  mv "$state_tmp" "$STATE_FILE"
}

latest_download_progress() {
  [[ -f "$STATE_FILE" ]] || return 1
  grep '^DOWNLOAD_PROGRESS|' "$STATE_FILE" 2>/dev/null | tail -n 1
}

emit_download_progress_line() {
  local elapsed="$1" label="$2" percent="$3" downloaded="$4" total="$5" remaining="$6"
  printf '[已用 %s] 正在下载%s：%s%%（%sMB/%sMB，约剩 %s 分钟）\n' \
    "$(format_elapsed_mmss "$elapsed")" \
    "$label" \
    "$percent" \
    "$(format_megabytes "$downloaded")" \
    "$(format_megabytes "$total")" \
    "$remaining" >&3
}

emit_download_progress_without_total() {
  local elapsed="$1" label="$2" downloaded="$3"
  printf '[已用 %s] 正在下载%s：已下载 %sMB（速度 %sKB/s）\n' \
    "$(format_elapsed_mmss "$elapsed")" \
    "$label" \
    "$(format_megabytes "$downloaded")" \
    "$(format_download_speed_kbps "$downloaded" "$elapsed")" >&3
}

emit_download_progress_updates() {
  local record marker label percent downloaded total remaining elapsed key
  record="$(latest_download_progress || true)"
  [[ -n "$record" ]] || return 0
  IFS='|' read -r marker label percent downloaded total remaining elapsed <<<"$record"
  [[ "$marker" == DOWNLOAD_PROGRESS ]] || return 0
  [[ "$percent" == unknown || "$percent" =~ ^[0-9]+$ ]] || return 0
  [[ "$downloaded" =~ ^[0-9]+$ && "$total" =~ ^[0-9]+$ && "$remaining" =~ ^[0-9]+$ && "$elapsed" =~ ^[0-9]+$ ]] || return 0
  key="$label|$percent|$downloaded|$total|$remaining|$elapsed"
  [[ "$key" == "${DOWNLOAD_PROGRESS_LAST:-}" ]] && return 0
  DOWNLOAD_PROGRESS_LAST="$key"
  if [[ "$percent" == unknown || "$total" == 0 ]]; then
    emit_download_progress_without_total "$elapsed" "$label" "$downloaded"
  else
    emit_download_progress_line "$elapsed" "$label" "$percent" "$downloaded" "$total" "$remaining"
  fi
}

download_reports_directly() {
  [[ "${RUN_CONTEXT:-}" != *_supervisor ]]
}

download_url_with_progress() {
  local target="$1" label="$2" expected_bytes="${3:-0}" url="$4"
  local progress_file curl_pid start_epoch now elapsed last_report
  local total_bytes downloaded_bytes percent curl_percent remaining_minutes

  [[ "$expected_bytes" =~ ^[0-9]+$ ]] || expected_bytes=0
  total_bytes="$expected_bytes"

  progress_file="$WORK_DIR/curl-progress.$$.txt"
  rm -f "$target" "$progress_file"
  start_epoch="$(date +%s)"
  last_report=-12

  curl -fL --progress-bar --connect-timeout 15 --retry 2 --retry-delay 2 \
    --max-time "$DOWNLOAD_TIMEOUT" -o "$target" "$url" 2>"$progress_file" &
  curl_pid=$!

  while kill -0 "$curl_pid" 2>/dev/null; do
    now="$(date +%s)"
    elapsed=$((now - start_epoch))
    if (( elapsed - last_report >= 12 )); then
      downloaded_bytes="$(downloaded_file_size "$target")"
      [[ "$downloaded_bytes" =~ ^[0-9]+$ ]] || downloaded_bytes=0
      if (( total_bytes > 0 )); then
        percent=$((downloaded_bytes * 100 / total_bytes))
        curl_percent="$(curl_progress_percent "$progress_file" || true)"
        if [[ "$curl_percent" =~ ^[0-9]+$ ]] && (( curl_percent > percent && curl_percent < 100 )); then
          percent="$curl_percent"
        fi
        (( percent > 99 )) && percent=99
        remaining_minutes="$(download_remaining_minutes "$downloaded_bytes" "$total_bytes" "$elapsed")"
        state_update_download_progress "$label" "$percent" "$downloaded_bytes" "$total_bytes" "$remaining_minutes" "$elapsed"
        if download_reports_directly; then
          emit_download_progress_line "$elapsed" "$label" "$percent" "$downloaded_bytes" "$total_bytes" "$remaining_minutes"
        fi
      else
        state_update_download_progress "$label" unknown "$downloaded_bytes" 0 0 "$elapsed"
        if download_reports_directly; then
          emit_download_progress_without_total "$elapsed" "$label" "$downloaded_bytes"
        fi
      fi
      last_report="$elapsed"
    fi
    sleep 1
  done

  if wait "$curl_pid"; then
    now="$(date +%s)"
    elapsed=$((now - start_epoch))
    downloaded_bytes="$(downloaded_file_size "$target")"
    [[ "$downloaded_bytes" =~ ^[0-9]+$ ]] || downloaded_bytes=0
    if (( total_bytes > 0 )); then
      (( total_bytes < downloaded_bytes )) && total_bytes="$downloaded_bytes"
      state_update_download_progress "$label" 100 "$downloaded_bytes" "$total_bytes" 0 "$elapsed"
      if download_reports_directly; then
        emit_download_progress_line "$elapsed" "$label" 100 "$downloaded_bytes" "$total_bytes" 0
      fi
    else
      state_update_download_progress "$label" unknown "$downloaded_bytes" 0 0 "$elapsed"
      if download_reports_directly; then
        emit_download_progress_without_total "$elapsed" "$label" "$downloaded_bytes"
      fi
    fi
    rm -f "$progress_file"
    return 0
  fi

  rm -f "$progress_file"
  return 1
}

download_first_with_progress() {
  local dest="$1" label="$2" expected_bytes="${3:-0}"
  shift 3
  local url tmp
  tmp="${dest}.tmp"
  rm -f "$tmp"

  for url in "$@"; do
    [[ -n "$url" ]] || continue
    log "正在下载${label}"
    if download_url_with_progress "$tmp" "$label" "$expected_bytes" "$url"; then
      mv "$tmp" "$dest"
      return 0
    fi
    rm -f "$tmp"
    log "当前下载源不可用，继续尝试下一个源"
  done

  return 1
}

terminal_marker_fields() {
  case "$1" in
    INSTALL_STARTED|BACKGROUND_SUPERVISOR_STARTED)
      printf '1|start|正在启动安装|3\n'
      ;;
    STEP_1_STARTED)
      printf '4|system|正在检查系统环境|5\n'
      ;;
    STEP_1_DONE)
      printf '6|deps|正在准备必要依赖|7\n'
      ;;
    STEP_2_STARTED)
      printf '8|openclaw_install|正在升级龙虾|21\n'
      ;;
    STEP_2_DONE)
      printf '22|openclaw_done|正在配置龙虾|23\n'
      ;;
    STEP_3_STARTED)
      printf '24|connector|正在安装灯光插件|25\n'
      ;;
    LIGHT_COMPONENT_DOWNLOAD_STARTED)
      printf '26|download|正在下载Miloco组件包|27\n'
      ;;
    LIGHT_SERVICE_INSTALL_STARTED|LIGHT_COMPONENT_DOWNLOAD_DONE|MILOCO_INSTALL_STARTED)
      printf '28|service|正在安装灯光服务|29\n'
      ;;
    STEP_3_DONE|STEP_4_STARTED|STEP_4_DONE|STEP_5_STARTED)
      printf '30|installer|正在预置馨光 Skill 安装器|31\n'
      ;;
    XINGUANG_SKILL_INSTALLER_READY)
      printf '32|installer|正在预置馨光 Skill 安装器|33\n'
      ;;
    STEP_5_DONE)
      printf '34|local_tools|正在下载维护面板和本地工具|45\n'
      ;;
    GATEWAY_SERVICE_REPAIR_STARTED|GATEWAY_SERVICE_ACTIVE)
      printf '34|gateway_recover|正在启动龙虾服务|90\n'
      ;;
    GATEWAY_RESTART_SCHEDULED|AGENTCHAT_RECONNECT_EXPECTED|GATEWAY_RESTART_DONE)
      printf '46|gateway_recover|正在启动龙虾服务|90\n'
      ;;
    STEP_6_STARTED)
      printf '53|verify|正在验证安装结果|99\n'
      ;;
    STEP_6_DONE|SUCCESS_ACTIVE|SUCCESS_AFTER_RECONNECT)
      printf '100|complete|安装完成|100\n'
      ;;
    OPENCLAW_GATEWAY_RECOVERY_FAILED|WAINFORT_SERVER_DATA_DIR_UNSUPPORTED|WAINFORT_SERVER_START_FAILED|ERROR:*|EXITED_BUT_INCOMPLETE)
      printf '0|error|安装未完成，请联系工作人员处理|0\n'
      ;;
    *)
      return 1
      ;;
  esac
}

terminal_progress_message_for_marker() {
  local fields percent phase label phase_max
  fields="$(terminal_marker_fields "$1" || true)"
  [[ -n "$fields" ]] || return 1
  IFS='|' read -r percent phase label phase_max <<<"$fields"

  case "$phase" in
    complete)
      printf '[100%%] 基础环境安装完成。\n\n下一步：\n请回到腾讯云控制台的 Agent 对话页面（Agent 控制台），发送「绑定米家账号」。\n'
      ;;
    error)
      printf '安装未完成，请联系工作人员处理。\n'
      ;;
    *)
      printf '[已用 00:01] %s%% %s...\n' "$percent" "$label"
      ;;
  esac
}

terminal_best_progress_fields() {
  local marker fields percent phase label phase_max
  local best_percent=-1
  local best_fields=''

  if install_complete_state; then
    terminal_marker_fields STEP_6_DONE
    return
  fi

  if [[ ! -f "$STATE_FILE" ]]; then
    terminal_marker_fields INSTALL_STARTED
    return
  fi

  if install_failed_state; then
    terminal_marker_fields EXITED_BUT_INCOMPLETE
    return
  fi

  while IFS= read -r marker; do
    fields="$(terminal_marker_fields "$marker" || true)"
    [[ -n "$fields" ]] || continue
    IFS='|' read -r percent phase label phase_max <<<"$fields"
    if (( percent > best_percent )); then
      best_percent="$percent"
      best_fields="$fields"
    fi
  done <"$STATE_FILE"

  if [[ -n "$best_fields" ]]; then
    printf '%s\n' "$best_fields"
  else
    terminal_marker_fields INSTALL_STARTED
  fi
}

progress_message_for_marker() {
  case "$1" in
    STEP_1_STARTED|STEP_1_DONE|STEP_2_STARTED)
      printf '当前进度：\n1/4 正在准备安装环境\n'
      ;;
    STEP_2_DONE|STEP_3_STARTED|PLUGIN_READY)
      printf '当前进度：\n2/4 正在安装灯光插件\n'
      ;;
    STEP_3_DONE|STEP_4_STARTED|STEP_4_DONE|STEP_5_STARTED|STEP_5_DONE|STEP_6_STARTED)
      printf '当前进度：\n3/4 正在准备米家连接\n'
      ;;
    GATEWAY_RESTART_SCHEDULED|AGENTCHAT_RECONNECT_EXPECTED)
      cat <<'EOF'
龙虾后台服务正在重启，请等待 1–3 分钟后刷新页面。
如果刷新后没有看到进度，请复制状态查询指令发给龙虾。
不要重复发送一键安装指令。
EOF
      ;;
    GATEWAY_RESTART_DONE)
      printf '当前进度：\n3/4 正在准备米家连接\n'
      ;;
    GATEWAY_SERVICE_REPAIR_STARTED)
      printf '龙虾后台服务正在恢复，请稍候...\n'
      ;;
    STEP_6_DONE|SUCCESS_ACTIVE|SUCCESS_AFTER_RECONNECT)
      printf '[100%%] 基础环境安装完成。\n\n下一步：\n请发送「绑定米家账号」。\n'
      ;;
    OPENCLAW_GATEWAY_RECOVERY_FAILED|WAINFORT_SERVER_DATA_DIR_UNSUPPORTED|WAINFORT_SERVER_START_FAILED|ERROR:*|EXITED_BUT_INCOMPLETE)
      printf '安装未完成，请联系工作人员处理。\n'
      ;;
    *)
      return 1
      ;;
  esac
}

emit_mimo_key_log_updates() {
  local seen_file="$1"
  local line key

  [[ -f "$LOG_FILE" ]] || return 0
  while IFS= read -r line; do
    [[ "$line" == *"MiMo Key"* ]] || continue
    key="MIMO_KEY_LOG:$line"
    if ! grep -Fxq -- "$key" "$seen_file" 2>/dev/null; then
      printf '%s\n' "$line"
      printf '%s\n' "$key" >>"$seen_file"
    fi
  done <"$LOG_FILE"
}

status_running_hint() {
  if [[ "${RUN_CONTEXT:-}" == agentchat* ]]; then
    printf '\n请继续等待，不要重复发送一键安装指令。\n'
  else
    printf '\n请继续等待，不要重复执行安装命令。\n'
  fi
}

status_complete_message() {
  cat <<'EOF'
[100%] 基础环境安装完成。

下一步：
请回到腾讯云控制台的 Agent 对话页面（Agent 控制台），发送「绑定米家账号」。
EOF
}

status_restart_message() {
  if [[ "${RUN_CONTEXT:-}" == agentchat* ]]; then
    cat <<'EOF'
龙虾后台服务正在重启，请等待 1–3 分钟后刷新页面。
如果刷新后没有看到进度，请复制状态查询指令发给龙虾。
不要重复发送一键安装指令。
EOF
  else
    cat <<'EOF'
龙虾后台服务正在重启，安装仍在继续。
请稍等 1–3 分钟后重新运行：

bash install-xinguang-ai-light.sh status

不要重复执行安装命令。
EOF
  fi
}

terminal_status_report() {
  local fields percent phase label phase_max
  fields="$(terminal_best_progress_fields)"
  IFS='|' read -r percent phase label phase_max <<<"$fields"

  case "$phase" in
    complete)
      cat <<'EOF'
[100%] 基础环境安装完成。

下一步：
请回到腾讯云控制台的 Agent 对话页面（Agent 控制台），发送「绑定米家账号」。
EOF
      ;;
    error)
      printf '安装未完成，请联系工作人员处理。\n'
      ;;
    *)
      printf '[%s%%] %s...\n\n请继续等待，不要重复执行安装命令。\n' "$percent" "$label"
      ;;
  esac
}

emit_progress_updates() {
  local seen_file="$1"
  [[ -f "$STATE_FILE" ]] || return 0

  local marker message key
  while IFS= read -r marker; do
    message="$(progress_message_for_marker "$marker" || true)"
    [[ -n "$message" ]] || continue
    key="$marker"
    case "$marker" in
      STEP_1_STARTED|STEP_1_DONE|STEP_2_STARTED) key="PHASE_1_PREP" ;;
      STEP_2_DONE|STEP_3_STARTED|PLUGIN_READY) key="PHASE_2_PLUGIN" ;;
      STEP_3_DONE|STEP_4_STARTED|STEP_4_DONE|STEP_5_STARTED|STEP_5_DONE|STEP_6_STARTED|GATEWAY_RESTART_DONE) key="PHASE_3_MIJIA" ;;
      GATEWAY_SERVICE_REPAIR_STARTED) key="GATEWAY_SERVICE_REPAIR" ;;
      GATEWAY_RESTART_SCHEDULED|AGENTCHAT_RECONNECT_EXPECTED) key="RECONNECT_EXPECTED" ;;
      STEP_6_DONE|SUCCESS_ACTIVE|SUCCESS_AFTER_RECONNECT) key="INSTALL_COMPLETE" ;;
      OPENCLAW_GATEWAY_RECOVERY_FAILED|WAINFORT_SERVER_DATA_DIR_UNSUPPORTED|WAINFORT_SERVER_START_FAILED|ERROR:*|EXITED_BUT_INCOMPLETE) key="INSTALL_INCOMPLETE_OR_ERROR" ;;
    esac
    if ! grep -Fxq "$key" "$seen_file" 2>/dev/null; then
      printf '%s\n' "$message" >&3
      printf '%s\n' "$key" >>"$seen_file"
    fi
  done <"$STATE_FILE"
  emit_mimo_key_log_updates "$seen_file"
}

terminal_emit_progress() {
  local percent="$1"
  local phase="$2"
  local label="$3"
  local phase_max="$4"
  local elapsed="${5:-0}"

  if [[ "$phase" == error ]]; then
    if [[ "${TERMINAL_CURRENT_PHASE:-}" != error ]]; then
      TERMINAL_CURRENT_PHASE="error"
      printf '安装未完成，请联系工作人员处理。\n' >&3
    fi
    return 0
  fi

  if [[ "$phase" == complete ]]; then
    if (( TERMINAL_MAX_PERCENT < 100 )); then
      TERMINAL_MAX_PERCENT=100
      TERMINAL_CURRENT_PHASE="complete"
      TERMINAL_CURRENT_LABEL="基础环境安装完成"
      TERMINAL_CURRENT_PHASE_MAX=100
      printf '[100%%] 基础环境安装完成。\n\n下一步：\n请回到腾讯云控制台的 Agent 对话页面（Agent 控制台），发送「绑定米家账号」。\n' >&3
    fi
    return 0
  fi

  if (( percent < TERMINAL_MAX_PERCENT )); then
    return 0
  fi

  if [[ "$phase" != "$TERMINAL_CURRENT_PHASE" ]]; then
    TERMINAL_CURRENT_PHASE="$phase"
    TERMINAL_CURRENT_LABEL="$label"
    TERMINAL_CURRENT_PHASE_MAX="$phase_max"
    TERMINAL_PHASE_STARTED_ELAPSED="$elapsed"
  else
    TERMINAL_CURRENT_LABEL="$label"
    TERMINAL_CURRENT_PHASE_MAX="$phase_max"
  fi

  if (( percent > TERMINAL_MAX_PERCENT )); then
    local display_elapsed formatted
    display_elapsed="$elapsed"
    (( display_elapsed < 1 )) && display_elapsed=1
    formatted="$(format_elapsed_mmss "$display_elapsed")"
    TERMINAL_MAX_PERCENT="$percent"
    printf '[已用 %s] %s%% %s...\n' "$formatted" "$percent" "$label" >&3
  fi
}

emit_terminal_progress_updates() {
  local seen_file="$1"
  local elapsed="${2:-0}"
  [[ -f "$STATE_FILE" ]] || return 0

  local marker fields percent phase label phase_max
  while IFS= read -r marker; do
    fields="$(terminal_marker_fields "$marker" || true)"
    [[ -n "$fields" ]] || continue
    IFS='|' read -r percent phase label phase_max <<<"$fields"
    terminal_emit_progress "$percent" "$phase" "$label" "$phase_max" "$elapsed"
  done <"$STATE_FILE"
  emit_mimo_key_log_updates "$seen_file"
}

terminal_heartbeat_message() {
  local elapsed="$1"
  local formatted phase_elapsed percent label

  (( TERMINAL_MAX_PERCENT > 0 && TERMINAL_MAX_PERCENT < 100 )) || return 0

  formatted="$(format_elapsed_mmss "$elapsed")"
  phase_elapsed=$((elapsed - TERMINAL_PHASE_STARTED_ELAPSED))
  (( phase_elapsed < 0 )) && phase_elapsed=0
  percent=$((TERMINAL_MAX_PERCENT + 1))
  if (( percent > TERMINAL_CURRENT_PHASE_MAX )); then
    percent="$TERMINAL_CURRENT_PHASE_MAX"
  fi
  if (( percent > TERMINAL_MAX_PERCENT )); then
    TERMINAL_MAX_PERCENT="$percent"
  fi

  label="$TERMINAL_CURRENT_LABEL"
  if (( phase_elapsed >= 900 )); then
    if [[ "$TERMINAL_CURRENT_PHASE" == skill ]]; then
      printf '[已用 %s] %s%% 馨光 Skill 安装时间较长，仍在继续。请不要重复执行安装命令。\n' "$formatted" "$percent"
    else
      printf '[已用 %s] %s%% %s时间较长，仍在继续。请不要重复执行安装命令。\n' "$formatted" "$percent" "$label"
    fi
  elif (( phase_elapsed >= 300 )); then
    printf '[已用 %s] %s%% %s，时间较长，请继续等待...\n' "$formatted" "$percent" "$label"
  else
    printf '[已用 %s] %s%% %s，请稍候...\n' "$formatted" "$percent" "$label"
  fi
}

state_latest_marker() {
  [[ -f "$STATE_FILE" ]] || {
    printf 'INSTALL_STARTED'
    return
  }
  tail -n 1 "$STATE_FILE" 2>/dev/null || printf 'INSTALL_STARTED'
}

install_failed_state() {
  state_has EXITED_BUT_INCOMPLETE && return 0
  state_has OPENCLAW_GATEWAY_RECOVERY_FAILED && return 0
  state_has WAINFORT_SERVER_DATA_DIR_UNSUPPORTED && return 0
  state_has WAINFORT_SERVER_START_FAILED && return 0
  grep -q '^ERROR:' "$STATE_FILE" 2>/dev/null
}

observe_terminal_background_progress() {
  local max_seconds="${FRONT_PROGRESS_MAX_SECONDS:-1800}"
  local interval="${FRONT_PROGRESS_INTERVAL_SECONDS:-5}"
  local heartbeat_seconds="${FRONT_PROGRESS_HEARTBEAT_SECONDS:-15}"
  local elapsed=0
  local heartbeat_elapsed=0
  local seen_file="$WORK_DIR/terminal-progress-seen.txt"
  : >"$seen_file"
  TERMINAL_MAX_PERCENT=0
  TERMINAL_CURRENT_PHASE=""
  TERMINAL_CURRENT_LABEL=""
  TERMINAL_CURRENT_PHASE_MAX=0
  TERMINAL_PHASE_STARTED_ELAPSED=0

  printf '\n开始安装，请稍候。\n\n'

  while (( elapsed <= max_seconds )); do
    if install_complete_state; then
      terminal_emit_progress 100 complete "安装完成" 100 "$elapsed"
      return 0
    fi
    if install_failed_state; then
      if [[ "${TERMINAL_CURRENT_PHASE:-}" != error ]]; then
        printf '安装未完成，请联系工作人员处理。\n' >&3
      fi
      return 0
    fi
    emit_terminal_progress_updates "$seen_file" "$elapsed"
    emit_download_progress_updates
    if (( elapsed >= max_seconds )); then
      break
    fi
    sleep "$interval"
    elapsed=$((elapsed + interval))
    heartbeat_elapsed=$((heartbeat_elapsed + interval))
    if (( heartbeat_elapsed >= heartbeat_seconds )); then
      if install_complete_state; then
        terminal_emit_progress 100 complete "安装完成" 100 "$elapsed"
        return 0
      fi
      terminal_heartbeat_message "$elapsed" >&3
      heartbeat_elapsed=0
    fi
  done

  if install_complete_state; then
    terminal_emit_progress 100 complete "安装完成" 100 "$elapsed"
    return 0
  fi
  emit_terminal_progress_updates "$seen_file" "$elapsed"
  emit_download_progress_updates

  if background_supervisor_running; then
    terminal_heartbeat_message "$elapsed" >&3
    cat >&3 <<'EOF'

如果超过 2 分钟没有新进度，可在当前终端运行：
bash install-xinguang-ai-light.sh status
不要重复执行安装命令。
EOF
  else
    printf '\n安装未完成，请联系工作人员处理。\n' >&3
  fi
}

background_pid_running() {
  local pid=""
  if [[ -s "$PID_FILE" ]]; then
    pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  fi
  [[ "$pid" =~ ^[0-9]+$ ]] && ps -p "$pid" >/dev/null 2>&1
}

background_supervisor_running() {
  background_pid_running && return 0
  have systemctl && systemctl --user is-active --quiet "$SUPERVISOR_UNIT" >/dev/null 2>&1
}

observe_background_progress() {
  if [[ "${RUN_CONTEXT:-}" == terminal* ]]; then
    observe_terminal_background_progress
    return
  fi

  local max_seconds="${FRONT_PROGRESS_MAX_SECONDS:-480}"
  local interval="${FRONT_PROGRESS_INTERVAL_SECONDS:-5}"
  local elapsed=0
  local seen_file="$WORK_DIR/frontend-progress-seen.txt"
  : >"$seen_file"

  printf '\n开始安装，请稍候。\n'
  printf '\n当前进度：\n1/4 正在准备安装环境\n'
  printf 'PHASE_1_PREP\n' >>"$seen_file"

  while (( elapsed <= max_seconds )); do
    if install_complete_state; then
      status_complete_message >&3
      return 0
    fi
    if state_has GATEWAY_RESTART_SCHEDULED || state_has AGENTCHAT_RECONNECT_EXPECTED; then
      return 0
    fi
    if install_failed_state; then
      printf '安装未完成，请联系工作人员处理。\n'
      return 0
    fi
    emit_progress_updates "$seen_file"
    emit_download_progress_updates
    if (( elapsed >= max_seconds )); then
      break
    fi
    sleep "$interval"
    elapsed=$((elapsed + interval))
  done

  if install_complete_state; then
    status_complete_message >&3
    return 0
  fi
  emit_progress_updates "$seen_file"
  emit_download_progress_updates
  if install_failed_state; then
    printf '安装未完成，请联系工作人员处理。\n'
    return 0
  fi

  if background_supervisor_running; then
    cat <<EOF

当前安装未完成，请稍后查询进度。
如果超过 2 分钟没有新进度，请复制状态查询指令发给龙虾。
不要重复发送一键安装指令。
EOF
  else
    cat <<EOF

安装未完成，请联系工作人员处理。
如果超过 2 分钟没有新进度，请复制状态查询指令发给龙虾。
不要重复发送一键安装指令。
EOF
  fi
}

launch_background_supervisor() {
  local launcher="/tmp/openclaw-miloco-install-supervisor.sh"
  local start_method="setsid-nohup"
  local unit="$SUPERVISOR_UNIT"

  INSTALL_ACTION="${INSTALL_ACTION:-full}"
  mkdir -p "$(dirname "$LOG_FILE")" "$(dirname "$STATE_FILE")" "$(dirname "$PID_FILE")"
  : >"$LOG_FILE"
  rm -f "$PID_FILE"
  state_init
  : >"$STATE_FILE"
  state_mark_silent BACKGROUND_SUPERVISOR_STARTED
  write_supervisor_launcher "$launcher"

  if [[ -z "$DEEPSEEK_API_KEY" ]] && have systemd-run &&
    systemd-run --user --unit="$unit" --collect --property=Restart=no \
      --setenv="STATE_FILE=$STATE_FILE" \
      --setenv="LOG_FILE=$LOG_FILE" \
      --setenv="PID_FILE=$PID_FILE" \
      /bin/bash "$launcher" >/dev/null 2>&1; then
    start_method="systemd-run --user"
  else
    setsid nohup /bin/bash "$launcher" </dev/null >>"$LOG_FILE" 2>&1 &
    printf '%s\n' "$!" >"$PID_FILE"
  fi

  local wait_i pid=""
  for wait_i in {1..10}; do
    if [[ -s "$PID_FILE" ]]; then
      pid="$(cat "$PID_FILE" 2>/dev/null || true)"
      break
    fi
    sleep 0.2
  done

  observe_background_progress
}

die() {
  printf '\n安装未完成，请联系工作人员处理。\n' >&2
  exit 1
}

on_error() {
  local status=$?
  printf '\n安装未完成，请联系工作人员处理。\n' >&2
  print_incomplete_report "script exited with code $status" || true
}

trap on_error ERR

have() {
  command -v "$1" >/dev/null 2>&1
}

append_path_once() {
  local line="$1"
  local file="$HOME/.bashrc"
  touch "$file"
  grep -Fqx "$line" "$file" || printf '%s\n' "$line" >>"$file"
}

setup_runtime_paths() {
  local nvm_node_dir=""
  if [[ -d "$HOME/.nvm/versions/node" ]]; then
    nvm_node_dir="$(find "$HOME/.nvm/versions/node" -maxdepth 1 -type d -name 'v*' 2>/dev/null | sort -V | tail -1 || true)"
  fi

  export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$HOME/.local/share/pnpm:$HOME/.local/share/pnpm/global/5/node_modules/.bin:$PATH"
  if [[ -n "$nvm_node_dir" && -d "$nvm_node_dir/bin" ]]; then
    export PATH="$nvm_node_dir/bin:$PATH"
  fi

  append_path_once 'export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$HOME/.local/share/pnpm:$HOME/.local/share/pnpm/global/5/node_modules/.bin:$PATH"'
  append_path_once 'if [ -d "$HOME/.nvm/versions/node" ]; then NODE_DIR="$(find "$HOME/.nvm/versions/node" -maxdepth 1 -type d -name '\''v*'\'' 2>/dev/null | sort -V | tail -1)"; [ -n "$NODE_DIR" ] && export PATH="$NODE_DIR/bin:$PATH"; fi'
}

normalize_version_tag() {
  if [[ "$MILOCO_VERSION" == latest ]]; then
    printf 'latest'
  elif [[ "$MILOCO_VERSION" == v* ]]; then
    printf '%s' "$MILOCO_VERSION"
  else
    printf 'v%s' "$MILOCO_VERSION"
  fi
}

version_ge() {
  local actual="$1"
  local required="$2"
  [[ "$actual" == "$required" ]] && return 0
  [[ "$(printf '%s\n%s\n' "$required" "$actual" | sort -V | head -n 1)" == "$required" ]]
}

openclaw_version_number() {
  openclaw --version 2>/dev/null | sed -nE 's/.*([0-9]{4}\.[0-9]+\.[0-9]+).*/\1/p' | head -n 1
}

openclaw_gateway_version_number() {
  local status_file="$WORK_DIR/openclaw-gateway-version.json"
  if timeout 15s openclaw gateway status --json >"$status_file" 2>/dev/null; then
    jq -r '.gateway.version // .gatewayVersion // .version // empty' "$status_file" 2>/dev/null |
      sed -nE 's/.*([0-9]{4}\.[0-9]+\.[0-9]+).*/\1/p' |
      head -n 1
  fi
}

report_openclaw_versions() {
  local cli_version gateway_version
  cli_version="$(openclaw_version_number || true)"
  gateway_version="$(openclaw_gateway_version_number || true)"
  log "OpenClaw CLI version: ${cli_version:-unknown}"
  log "OpenClaw Gateway version: ${gateway_version:-unknown}"
  if [[ -n "$cli_version" && -n "$gateway_version" && "$cli_version" != "$gateway_version" ]]; then
    log "WARNING: OpenClaw CLI/Gateway version mismatch: CLI $cli_version, Gateway $gateway_version"
  fi
}

platform_key() {
  local machine
  machine="$(uname -m)"
  case "$machine" in
    x86_64|amd64) printf 'linux-x86_64' ;;
    aarch64|arm64) printf 'linux-aarch64' ;;
    *) die "Unsupported architecture: $machine" ;;
  esac
}

download_first() {
  local dest="$1"
  shift
  local url tmp
  tmp="${dest}.tmp"
  rm -f "$tmp"

  for url in "$@"; do
    [[ -n "$url" ]] || continue
    log "Downloading: $url"
    if curl -fL --connect-timeout 15 --retry 2 --retry-delay 2 \
      --max-time "$DOWNLOAD_TIMEOUT" -o "$tmp" "$url"; then
      mv "$tmp" "$dest"
      return 0
    fi
    rm -f "$tmp"
    log "Download failed, trying next source"
  done

  return 1
}

benchmark_url() {
  local url="$1"
  local use_range="${2:-0}"
  local args=()
  [[ "$use_range" == 1 ]] && args=(--range "$MIRROR_TEST_RANGE")
  curl -fsSL "${args[@]}" \
    --connect-timeout 5 \
    --max-time "$MIRROR_TEST_TIMEOUT" \
    -o /dev/null \
    -w '%{time_total}' \
    "$url" 2>/dev/null
}

rank_urls_by_speed() {
  local label="$1"
  local use_range="$2"
  shift 2

  local urls=("$@")
  if [[ "${#urls[@]}" -eq 0 ]]; then
    local input_url
    while IFS= read -r input_url; do
      urls+=("$input_url")
    done
  fi

  if [[ "$AUTO_SELECT_MIRRORS" != 1 || "${#urls[@]}" -le 1 ]]; then
    printf '%s\n' "${urls[@]}"
    return
  fi

  local result_file failed_file url elapsed
  result_file="$WORK_DIR/${label//[^A-Za-z0-9_]/_}.speed"
  failed_file="$WORK_DIR/${label//[^A-Za-z0-9_]/_}.failed"
  : >"$result_file"
  : >"$failed_file"

  log "Benchmarking $label sources"
  for url in "${urls[@]}"; do
    [[ -n "$url" ]] || continue
    if elapsed="$(benchmark_url "$url" "$use_range")"; then
      log "  ${elapsed}s  $url"
      printf '%s\t%s\n' "$elapsed" "$url" >>"$result_file"
    else
      log "  failed  $url"
      printf '%s\n' "$url" >>"$failed_file"
    fi
  done

  if [[ -s "$result_file" ]]; then
    sort -n "$result_file" | cut -f2-
  fi
  cat "$failed_file"
}

split_lines() {
  tr ', ' '\n\n' | sed '/^$/d'
}

sha256_file() {
  if have sha256sum; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

require_ubuntu() {
  [[ -r /etc/os-release ]] || die "Cannot detect OS"
  # shellcheck disable=SC1091
  . /etc/os-release
  [[ "${ID:-}" == ubuntu ]] || die "This script is intended for Ubuntu. Detected: ${PRETTY_NAME:-unknown}"
}

apt_bootstrap() {
  log "Installing base packages"
  sudo env DEBIAN_FRONTEND=noninteractive apt-get update
  sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y \
    ca-certificates curl tar gzip unzip jq python3 python3-pip git build-essential

  if [[ "$RUN_SYSTEM_UPGRADE" == 1 ]]; then
    log "Applying system upgrades"
    sudo env DEBIAN_FRONTEND=noninteractive apt-get -y full-upgrade
    sudo env DEBIAN_FRONTEND=noninteractive apt-get -y autoremove
  else
    log "Skipping full system upgrade (RUN_SYSTEM_UPGRADE=0)"
  fi
}

download_openclaw_upgrade_script() {
  local installer="$WORK_DIR/openclaw-install.sh"
  download_first_with_progress "$installer" "龙虾升级安装器" 0 \
    "https://openclaw.ai/install.sh" || return 1
  chmod +x "$installer"
  printf '%s\n' "$installer"
}

directory_size_bytes() {
  local kib
  [[ -d "$1" ]] || {
    printf '0\n'
    return 0
  }
  kib="$({ du -sk "$1" 2>/dev/null || true; } | awk 'NR == 1 { print $1 }')"
  [[ "$kib" =~ ^[0-9]+$ ]] || kib=0
  printf '%s\n' "$((kib * 1024))"
}

openclaw_npm_cache_dir() {
  local cache_dir
  cache_dir="$(npm config get cache 2>/dev/null || true)"
  case "$cache_dir" in
    ""|null|undefined) printf '%s\n' "$HOME/.npm" ;;
    /*) printf '%s\n' "$cache_dir" ;;
    *) printf '%s/%s\n' "$PWD" "$cache_dir" ;;
  esac
}

openclaw_upgrade_expected_bytes() {
  if [[ "$OPENCLAW_UPGRADE_EXPECTED_BYTES" =~ ^[0-9]+$ ]] && (( OPENCLAW_UPGRADE_EXPECTED_BYTES > 0 )); then
    printf '%s\n' "$OPENCLAW_UPGRADE_EXPECTED_BYTES"
    return 0
  fi
  printf '0\n'
}

monitor_openclaw_upgrade_progress() {
  local installer_pid="$1" cache_dir="$2" baseline_bytes="$3" total_bytes="$4" start_epoch="$5"
  local now elapsed last_report cache_bytes downloaded_bytes percent remaining_minutes
  last_report=-12

  while kill -0 "$installer_pid" 2>/dev/null; do
    now="$(date +%s)"
    elapsed=$((now - start_epoch))
    if (( elapsed - last_report >= 12 )); then
      cache_bytes="$(directory_size_bytes "$cache_dir")"
      [[ "$cache_bytes" =~ ^[0-9]+$ ]] || cache_bytes=0
      downloaded_bytes=$((cache_bytes - baseline_bytes))
      (( downloaded_bytes < 0 )) && downloaded_bytes=0
      if (( total_bytes > 0 )); then
        percent=$((downloaded_bytes * 100 / total_bytes))
        (( percent > 99 )) && percent=99
        remaining_minutes="$(download_remaining_minutes "$downloaded_bytes" "$total_bytes" "$elapsed")"
        state_update_download_progress "龙虾升级组件" "$percent" "$downloaded_bytes" "$total_bytes" "$remaining_minutes" "$elapsed"
        if download_reports_directly; then
          emit_download_progress_line "$elapsed" "龙虾升级组件" "$percent" "$downloaded_bytes" "$total_bytes" "$remaining_minutes"
        fi
      else
        state_update_download_progress "龙虾升级组件" unknown "$downloaded_bytes" 0 0 "$elapsed"
        if download_reports_directly; then
          emit_download_progress_without_total "$elapsed" "龙虾升级组件" "$downloaded_bytes"
        fi
      fi
      last_report="$elapsed"
    fi
    sleep 1
  done
}

complete_openclaw_upgrade_progress() {
  local cache_dir="$1" baseline_bytes="$2" total_bytes="$3" start_epoch="$4"
  local now elapsed cache_bytes downloaded_bytes
  now="$(date +%s)"
  elapsed=$((now - start_epoch))
  cache_bytes="$(directory_size_bytes "$cache_dir")"
  [[ "$cache_bytes" =~ ^[0-9]+$ ]] || cache_bytes=0
  downloaded_bytes=$((cache_bytes - baseline_bytes))
  (( downloaded_bytes < 0 )) && downloaded_bytes=0
  if (( total_bytes > 0 )); then
    (( downloaded_bytes > total_bytes )) && total_bytes="$downloaded_bytes"
    state_update_download_progress "龙虾升级组件" 100 "$downloaded_bytes" "$total_bytes" 0 "$elapsed"
    if download_reports_directly; then
      emit_download_progress_line "$elapsed" "龙虾升级组件" 100 "$downloaded_bytes" "$total_bytes" 0
    fi
  else
    state_update_download_progress "龙虾升级组件" unknown "$downloaded_bytes" 0 0 "$elapsed"
    if download_reports_directly; then
      emit_download_progress_without_total "$elapsed" "龙虾升级组件" "$downloaded_bytes"
    fi
  fi
}

run_openclaw_installer_command() {
  local registry="$1" installer="$2"
  if [[ -n "$registry" ]]; then
    env \
      OPENCLAW_NO_PROMPT=1 \
      OPENCLAW_NO_ONBOARD=1 \
      OPENCLAW_INSTALL_METHOD=npm \
      npm_config_progress=false \
      npm_config_registry="$registry" \
      bash -s -- --no-onboard --no-prompt --install-method npm <"$installer"
  else
    env \
      OPENCLAW_NO_PROMPT=1 \
      OPENCLAW_NO_ONBOARD=1 \
      OPENCLAW_INSTALL_METHOD=npm \
      npm_config_progress=false \
      bash -s -- --no-onboard --no-prompt --install-method npm <"$installer"
  fi
}

run_openclaw_installer_with_registry() {
  local registry="$1" installer="$2"
  local cache_dir baseline_bytes total_bytes start_epoch installer_pid
  cache_dir="$(openclaw_npm_cache_dir)"
  baseline_bytes="$(directory_size_bytes "$cache_dir")"
  total_bytes="$(openclaw_upgrade_expected_bytes || true)"
  [[ "$total_bytes" =~ ^[0-9]+$ ]] || total_bytes=0
  start_epoch="$(date +%s)"

  run_openclaw_installer_command "$registry" "$installer" &
  installer_pid=$!

  monitor_openclaw_upgrade_progress "$installer_pid" "$cache_dir" "$baseline_bytes" "$total_bytes" "$start_epoch"

  if wait "$installer_pid"; then
    complete_openclaw_upgrade_progress "$cache_dir" "$baseline_bytes" "$total_bytes" "$start_epoch"
    return 0
  fi
  return 1
}

accept_openclaw_if_available() {
  setup_runtime_paths
  if have openclaw; then
    local version_text version_number
    version_text="$(openclaw --version 2>/dev/null || printf installed)"
    version_number="$(printf '%s\n' "$version_text" | sed -nE 's/.*([0-9]{4}\.[0-9]+\.[0-9]+).*/\1/p' | head -n 1)"
    log "OpenClaw command is available: $version_text"
    if [[ -z "$version_number" ]]; then
      log "Could not parse OpenClaw version; accepting command availability"
      return 0
    fi
    if version_ge "$version_number" "$OPENCLAW_MIN_VERSION"; then
      return 0
    fi
    log "OpenClaw version $version_number is below required $OPENCLAW_MIN_VERSION"
  fi
  return 1
}

run_openclaw_installer() {
  local registry installer
  installer="$(download_openclaw_upgrade_script)" || return 1
  registry="$(select_npm_registry)"
  if [[ -n "$registry" ]]; then
    log "Using npm registry: $registry"
    if ! run_openclaw_installer_with_registry "$registry" "$installer"; then
      log "OpenClaw install/update command returned non-zero with npm mirror; checking installed command"
      if accept_openclaw_if_available; then
        log "Continuing because OpenClaw is already usable after installer warning"
        return 0
      fi
      log "Retrying OpenClaw install/update with official npm registry"
      if ! run_openclaw_installer_with_registry "" "$installer"; then
        accept_openclaw_if_available || return 1
        log "Continuing because OpenClaw is usable after official-registry installer warning"
      fi
    fi
  else
    if ! run_openclaw_installer_with_registry "" "$installer"; then
      accept_openclaw_if_available || return 1
      log "Continuing because OpenClaw is usable after installer warning"
    fi
  fi
}

configure_openclaw_gateway() {
  local gateway_ok=0
  log "Configuring OpenClaw gateway"
  if timeout 240s openclaw onboard \
    --non-interactive \
    --accept-risk \
    --auth-choice skip \
    --install-daemon \
    --gateway-bind "$OPENCLAW_BIND" \
    --gateway-auth token \
    --gateway-port "$OPENCLAW_PORT" \
    --skip-channels \
    --skip-ui \
    --json; then
    log "OpenClaw onboard completed"
  else
    local status=$?
    log "OpenClaw onboard returned exit code $status; checking whether gateway is usable before failing"
  fi

  restart_openclaw_gateway_best_effort

  if ensure_openclaw_gateway_service_running; then
    gateway_ok=1
  fi

  if [[ "$gateway_ok" != 1 ]]; then
    state_mark OPENCLAW_GATEWAY_RECOVERY_FAILED
    die "龙虾后台服务暂未恢复"
  fi

  report_openclaw_versions || true

  return 0
}

install_openclaw() {
  setup_runtime_paths

  if ! have openclaw; then
    log "Installing OpenClaw"
    state_mark OPENCLAW_UPGRADE_REQUIRED
    state_mark OPENCLAW_UPGRADE_STARTED
    run_openclaw_installer
    setup_runtime_paths
    state_mark OPENCLAW_UPGRADE_DONE
  else
    local current_version
    current_version="$(openclaw_version_number || true)"
    log "OpenClaw already installed: $(openclaw --version 2>/dev/null || true)"
    if [[ "$OPENCLAW_UPDATE" == 1 ]]; then
      log "Updating OpenClaw"
      state_mark OPENCLAW_UPGRADE_REQUIRED
      state_mark OPENCLAW_UPGRADE_STARTED
      run_openclaw_installer
      setup_runtime_paths
      state_mark OPENCLAW_UPGRADE_DONE
    else
      if [[ -n "$current_version" ]] && ! version_ge "$current_version" "$OPENCLAW_MIN_VERSION"; then
        log "OpenClaw CLI version $current_version is below required $OPENCLAW_MIN_VERSION; updating with OPENCLAW_UPDATE=$OPENCLAW_UPDATE"
        state_mark OPENCLAW_UPGRADE_REQUIRED
        state_mark OPENCLAW_UPGRADE_STARTED
        run_openclaw_installer
        setup_runtime_paths
        state_mark OPENCLAW_UPGRADE_DONE
      else
        state_mark OPENCLAW_VERSION_OK
        log "Skipping OpenClaw package update (OPENCLAW_UPDATE=$OPENCLAW_UPDATE and installed version satisfies $OPENCLAW_MIN_VERSION)"
      fi
      if ensure_openclaw_gateway_service_running; then
        log "OpenClaw gateway already usable; skipping onboard reconfiguration"
        report_openclaw_versions || true
        return 0
      fi
      log "OpenClaw gateway is not ready; attempting lightweight gateway configuration"
    fi
  fi

  configure_openclaw_gateway
}

miloco_installer_urls() {
  if [[ -n "$MILOCO_INSTALLER_URLS" ]]; then
    printf '%s\n' "$MILOCO_INSTALLER_URLS" | split_lines
    return
  fi

  local tag
  tag="$(normalize_version_tag)"
  if [[ "$tag" == latest ]]; then
    cat <<'URLS'
https://github.com/XiaoMi/xiaomi-miloco/releases/latest/download/install.sh
https://gh-proxy.com/https://github.com/XiaoMi/xiaomi-miloco/releases/latest/download/install.sh
https://gh-proxy.org/https://github.com/XiaoMi/xiaomi-miloco/releases/latest/download/install.sh
https://gh.idayer.com/https://github.com/XiaoMi/xiaomi-miloco/releases/latest/download/install.sh
https://ghfast.top/https://github.com/XiaoMi/xiaomi-miloco/releases/latest/download/install.sh
https://ghproxy.net/https://github.com/XiaoMi/xiaomi-miloco/releases/latest/download/install.sh
URLS
  else
    cat <<URLS
https://github.com/XiaoMi/xiaomi-miloco/releases/download/$tag/install.sh
https://gh-proxy.com/https://github.com/XiaoMi/xiaomi-miloco/releases/download/$tag/install.sh
https://gh-proxy.org/https://github.com/XiaoMi/xiaomi-miloco/releases/download/$tag/install.sh
https://gh.idayer.com/https://github.com/XiaoMi/xiaomi-miloco/releases/download/$tag/install.sh
https://ghfast.top/https://github.com/XiaoMi/xiaomi-miloco/releases/download/$tag/install.sh
https://ghproxy.net/https://github.com/XiaoMi/xiaomi-miloco/releases/download/$tag/install.sh
URLS
  fi
}

extract_embedded_manifest() {
  local installer="$1"
  local manifest="$2"
  awk '
    found && $0 == "B64_MANIFEST" { exit }
    found { print }
    /B64_MANIFEST/ && /manifest\.json/ { found = 1 }
  ' "$installer" | base64 -d >"$manifest"
  jq -e . "$manifest" >/dev/null
}

manifest_value() {
  local manifest="$1"
  local query="$2"
  jq -r "$query" "$manifest"
}

miloco_bundle_urls() {
  local manifest="$1"
  local bundle_name="$2"
  if [[ -n "$MILOCO_BUNDLE_URLS" ]]; then
    printf '%s\n' "$MILOCO_BUNDLE_URLS" | split_lines
    return
  fi

  local tag site
  tag="$(manifest_value "$manifest" '.download.tag // empty')"
  if [[ -z "$tag" || "$tag" == "null" ]]; then
    tag="$(normalize_version_tag)"
  fi
  [[ "$tag" != latest ]] || die "Manifest has no concrete tag for latest release"

  {
    jq -r '.download.sites[]' "$manifest"
    cat <<'SITES'
https://ghfast.top/https://github.com/XiaoMi/xiaomi-miloco/releases/download
https://ghproxy.net/https://github.com/XiaoMi/xiaomi-miloco/releases/download
SITES
  } | awk '!seen[$0]++' | while IFS= read -r site; do
    site="${site%/}"
    printf '%s/%s/%s\n' "$site" "$tag" "$bundle_name"
  done
}

preload_miloco_bundle() {
  local installer="$1"
  local manifest="$WORK_DIR/manifest.json"
  local key version bundle_name bundle_sha bundle_size cache_dir archive persistent_dir persistent_archive

  extract_embedded_manifest "$installer" "$manifest"
  key="$(platform_key)"
  version="$(manifest_value "$manifest" '.version')"
  bundle_name="$(manifest_value "$manifest" ".bundles[\"$key\"].name")"
  bundle_sha="$(manifest_value "$manifest" ".bundles[\"$key\"].sha256")"
  bundle_size="$(manifest_value "$manifest" ".bundles[\"$key\"].size")"
  [[ -n "$bundle_name" && "$bundle_name" != "null" ]] || die "未找到当前系统可用的灯光插件组件"

  cache_dir="$MILOCO_HOME/.install-cache/$version"
  if compgen -G "$cache_dir/miloco-*.whl" >/dev/null &&
    compgen -G "$cache_dir/miloco-models-*.tar.gz" >/dev/null &&
    compgen -G "$cache_dir/*.tgz" >/dev/null; then
    log "灯光插件组件缓存已就绪"
    return
  fi

  archive="$WORK_DIR/$bundle_name"
  persistent_dir="$MILOCO_CLOUD_CACHE/$version"
  persistent_archive="$persistent_dir/$bundle_name"

  if [[ "$CACHE_MILOCO_BUNDLE" == 1 && -f "$persistent_archive" ]]; then
    local cached_sha
    cached_sha="$(sha256_file "$persistent_archive")"
    if [[ "$cached_sha" == "$bundle_sha" ]]; then
      log "使用已缓存的灯光插件组件"
      archive="$persistent_archive"
    else
      log "灯光插件组件缓存校验不一致，重新下载"
      rm -f "$persistent_archive"
    fi
  fi

  if [[ "$archive" != "$persistent_archive" ]]; then
    log "正在下载Miloco组件包"
    mapfile -t urls < <(miloco_bundle_urls "$manifest" "$bundle_name" | rank_urls_by_speed "灯光插件组件" 1)
    download_first_with_progress "$archive" "Miloco组件包" "$bundle_size" "${urls[@]}" || die "灯光插件组件下载失败"

    local actual_sha
    actual_sha="$(sha256_file "$archive")"
    [[ "$actual_sha" == "$bundle_sha" ]] || die "灯光插件组件校验失败: $actual_sha != $bundle_sha"

    if [[ "$CACHE_MILOCO_BUNDLE" == 1 ]]; then
      mkdir -p "$persistent_dir"
      cp -f "$archive" "$persistent_archive"
      log "已缓存灯光插件组件"
    fi
  fi

  rm -rf "$MILOCO_HOME/.install-cache"
  mkdir -p "$cache_dir"
  tar -xzf "$archive" -C "$cache_dir"

  compgen -G "$cache_dir/miloco-*.whl" >/dev/null || die "灯光插件组件不完整"
  compgen -G "$cache_dir/miloco-models-*.tar.gz" >/dev/null || die "灯光插件模型组件不完整"
  compgen -G "$cache_dir/*.tgz" >/dev/null || die "灯光插件扩展包不完整"
}

ensure_uv() {
  export PATH="$HOME/.local/bin:$PATH"
  if ! have uv; then
    log "Installing uv"
    curl -LsSf https://astral.sh/uv/install.sh | sh
    export PATH="$HOME/.local/bin:$PATH"
  fi
}

setup_wheelhouse_if_requested() {
  if [[ -z "$MILOCO_WHEELHOUSE_URL" ]]; then
    log "正在准备安装环境"
    return 0
  fi
  ensure_uv

  local archive="$WORK_DIR/miloco-wheelhouse.tar.gz"
  log "Downloading offline Python wheelhouse"
  download_first "$archive" "$MILOCO_WHEELHOUSE_URL" || die "Failed to download wheelhouse"
  mkdir -p "$WORK_DIR/wheelhouse"
  tar -xzf "$archive" -C "$WORK_DIR/wheelhouse"
  WHEELHOUSE_DIR="$(find "$WORK_DIR/wheelhouse" -type f -name '*.whl' -print -quit | xargs dirname)"
  [[ -n "$WHEELHOUSE_DIR" && -d "$WHEELHOUSE_DIR" ]] || die "Wheelhouse archive contains no .whl files"

  local real_uv
  real_uv="$(command -v uv)"
  UV_WRAPPER_DIR="$WORK_DIR/uv-wrapper"
  mkdir -p "$UV_WRAPPER_DIR"
  cat >"$UV_WRAPPER_DIR/uv" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "tool" && "\$2" == "install" ]]; then
  exec "$real_uv" tool install --no-index --find-links "$WHEELHOUSE_DIR" "\${@:3}"
fi
exec "$real_uv" "\$@"
EOF
  chmod +x "$UV_WRAPPER_DIR/uv"
  export PATH="$UV_WRAPPER_DIR:$PATH"
  log "Using offline wheelhouse: $WHEELHOUSE_DIR"
}

uv_index_url() {
  case "$1" in
    official|"")
      printf '%s' 'https://pypi.org/simple'
      ;;
    tuna|tsinghua)
      printf '%s' 'https://pypi.tuna.tsinghua.edu.cn/simple'
      ;;
    aliyun|ali)
      printf '%s' 'https://mirrors.aliyun.com/pypi/simple'
      ;;
    tencent)
      printf '%s' 'https://mirrors.cloud.tencent.com/pypi/simple'
      ;;
    ustc)
      printf '%s' 'https://mirrors.ustc.edu.cn/pypi/simple'
      ;;
    *)
      printf '%s' "$1"
      ;;
  esac
}

available_pypi_indexes() {
  cat <<'URLS'
https://pypi.tuna.tsinghua.edu.cn/simple
https://mirrors.ustc.edu.cn/pypi/simple
https://pypi.org/simple
URLS
}

select_pypi_index() {
  if [[ "$PYPI_INDEX" != auto ]]; then
    uv_index_url "$PYPI_INDEX"
    return
  fi

  if [[ "$AUTO_SELECT_MIRRORS" != 1 ]]; then
    printf '%s' 'https://pypi.org/simple'
    return
  fi

  local index test_url result_file failed_file elapsed
  result_file="$WORK_DIR/pypi.speed"
  failed_file="$WORK_DIR/pypi.failed"
  : >"$result_file"
  : >"$failed_file"

  log "正在准备安装环境"
  while IFS= read -r index; do
    [[ -n "$index" ]] || continue
    test_url="${index%/}/rich/"
    if elapsed="$(benchmark_url "$test_url" 0)"; then
      log "  ${elapsed}s  $index"
      printf '%s\t%s\n' "$elapsed" "$index" >>"$result_file"
    else
      log "  failed  $index"
      printf '%s\n' "$index" >>"$failed_file"
    fi
  done < <(available_pypi_indexes)

  if [[ -s "$result_file" ]]; then
    sort -n "$result_file" | head -1 | cut -f2-
  else
    printf '%s' 'https://pypi.org/simple'
  fi
}

available_npm_registries() {
  cat <<'URLS'
https://registry.npmmirror.com
https://registry.npmjs.org
https://mirrors.cloud.tencent.com/npm
https://mirrors.huaweicloud.com/repository/npm
URLS
}

probe_npm_registry() {
  local registry="$1"
  LC_ALL=C curl -fsSL \
    --connect-timeout 3 \
    --max-time 3 \
    -o /dev/null \
    -w '%{time_total}' \
    "${registry%/}/openclaw" 2>/dev/null
}

select_npm_registry() {
  if [[ "$NPM_REGISTRY" != auto ]]; then
    printf '%s' "$NPM_REGISTRY"
    return
  fi

  if [[ "$AUTO_SELECT_MIRRORS" != 1 ]]; then
    printf '%s' 'https://registry.npmmirror.com'
    return
  fi

  local registry elapsed best_registry="" best_elapsed=""
  local -a registries=(
    "https://registry.npmmirror.com"
    "https://mirrors.cloud.tencent.com/npm"
    "https://registry.npmjs.org"
  )

  for registry in "${registries[@]}"; do
    if elapsed="$(probe_npm_registry "$registry")"; then
      if [[ -z "$best_elapsed" ]] || awk -v candidate="$elapsed" -v best="$best_elapsed" 'BEGIN { exit !(candidate < best) }'; then
        best_registry="$registry"
        best_elapsed="$elapsed"
      fi
    fi
  done

  if [[ -n "$best_registry" ]]; then
    log "软件源优选：${best_registry#https://}（${best_elapsed}s）"
    printf '%s' "$best_registry"
  else
    log "软件源优选：registry.npmmirror.com（全部探测失败，回退默认源）"
    printf '%s' 'https://registry.npmmirror.com'
  fi
}

run_miloco_phase() {
  local installer="$1"
  local phase="$2"
  local index_url
  index_url="$(select_pypi_index)"

  log "灯光插件安装中"
  if UV_DEFAULT_INDEX="$index_url" PIP_INDEX_URL="$index_url" bash "$installer" "$phase" </dev/null; then
    return 0
  fi

  if [[ "$PYPI_FALLBACK_OFFICIAL" == 1 && "$index_url" != "https://pypi.org/simple" ]]; then
    log "当前安装源暂不可用，正在使用备用安装源重试"
    UV_DEFAULT_INDEX="https://pypi.org/simple" PIP_INDEX_URL="https://pypi.org/simple" bash "$installer" "$phase" </dev/null
    return $?
  fi

  return 1
}

wait_for_miloco_service() {
  log "正在等待灯光服务启动"
  local status_file="$WORK_DIR/miloco-service-status.json"
  local attempt
  for attempt in {1..30}; do
    if miloco-cli service status >"$status_file" 2>/dev/null &&
      jq -e '.running == true' "$status_file" >/dev/null 2>&1; then
      log "灯光服务已运行"
      return 0
    fi
    sleep 2
  done

  log "灯光服务暂未确认运行"
  return 1
}

wait_for_openclaw_gateway() {
  log "Waiting for OpenClaw gateway"
  local status_file="$WORK_DIR/openclaw-gateway-status.txt"
  local attempt
  for attempt in {1..20}; do
    if timeout 20s openclaw gateway status >"$status_file" 2>&1 &&
      grep -q 'Connectivity probe: ok' "$status_file"; then
      log "OpenClaw gateway connectivity probe is ok"
      return 0
    fi
    sleep 2
  done

  log "OpenClaw gateway did not report connectivity ok yet"
  sed -n '1,80p' "$status_file" 2>/dev/null || true
  return 1
}

openclaw_gateway_unit() {
  local unit
  for unit in openclaw-gateway.service openclaw_gateway.service; do
    if systemctl --user status "$unit" >/dev/null 2>&1; then
      printf '%s' "$unit"
      return 0
    fi
  done
  systemctl --user list-units --all --type=service --no-legend 2>/dev/null |
    awk 'tolower($1) ~ /openclaw/ && tolower($1) ~ /gateway/ {print $1; exit}'
}

openclaw_gateway_unit_file() {
  local unit="$1"
  local unit_file=""

  unit_file="$(systemctl --user show "$unit" -p FragmentPath --value 2>/dev/null || true)"
  if [[ -n "$unit_file" && "$unit_file" != "n/a" && -f "$unit_file" ]]; then
    printf '%s' "$unit_file"
    return 0
  fi

  unit_file="$HOME/.config/systemd/user/$unit"
  if [[ -f "$unit_file" ]]; then
    printf '%s' "$unit_file"
    return 0
  fi

  return 1
}

openclaw_gateway_service_active_running() {
  local unit="$1"
  local active sub

  active="$(systemctl --user show "$unit" -p ActiveState --value 2>/dev/null || true)"
  sub="$(systemctl --user show "$unit" -p SubState --value 2>/dev/null || true)"
  [[ "$active" == active && "$sub" == running ]]
}

repair_openclaw_gateway_execstart_if_needed() {
  setup_runtime_paths
  have systemctl || return 1
  have openclaw || return 1

  local unit unit_file current_openclaw exec_line args gateway_args new_line tmp
  unit="$(openclaw_gateway_unit || true)"
  [[ -n "$unit" ]] || return 1

  unit_file="$(openclaw_gateway_unit_file "$unit" || true)"
  [[ -n "$unit_file" ]] || return 1

  current_openclaw="$(command -v openclaw 2>/dev/null || true)"
  [[ -n "$current_openclaw" ]] || return 1

  exec_line="$(grep -E '^ExecStart=' "$unit_file" | tail -n 1 || true)"
  if [[ -n "$exec_line" ]]; then
    args="${exec_line#ExecStart=}"
    if [[ "$args" == "$current_openclaw "* ]]; then
      return 0
    fi
    if [[ "$args" == *" gateway"* ]]; then
      gateway_args="gateway${args#* gateway}"
    else
      gateway_args="gateway --port ${OPENCLAW_PORT}"
    fi
  else
    gateway_args="gateway --port ${OPENCLAW_PORT}"
  fi

  new_line="ExecStart=$current_openclaw $gateway_args"
  [[ "$exec_line" == "$new_line" ]] && return 0

  state_mark GATEWAY_SERVICE_REPAIR_STARTED
  log "龙虾后台服务正在恢复，请稍候..."

  tmp="$WORK_DIR/openclaw-gateway.service"
  awk -v new_line="$new_line" '
    BEGIN { replaced = 0 }
    /^ExecStart=/ {
      if (!replaced) {
        print new_line
        replaced = 1
      }
      next
    }
    { print }
    END {
      if (!replaced) {
        print new_line
      }
    }
  ' "$unit_file" >"$tmp"
  cat "$tmp" >"$unit_file"

  systemctl --user daemon-reload >/dev/null 2>&1 || return 1
  local unit_for_restart
  unit_for_restart="$(openclaw_gateway_unit || true)"
  if [[ -n "$unit_for_restart" ]]; then
    systemctl --user reset-failed "$unit_for_restart" >/dev/null 2>&1 || true
    systemctl --user restart "$unit_for_restart" >/dev/null 2>&1 || true
  fi
}

ensure_openclaw_gateway_service_running() {
  setup_runtime_paths
  have openclaw || return 1

  if ! have systemctl; then
    wait_for_openclaw_gateway
    return $?
  fi

  local unit attempt
  unit="$(openclaw_gateway_unit || true)"
  [[ -n "$unit" ]] || return 1

  repair_openclaw_gateway_execstart_if_needed || true

  if ! openclaw_gateway_service_active_running "$unit"; then
    state_mark GATEWAY_SERVICE_REPAIR_STARTED
    log "龙虾后台服务正在恢复，请稍候..."
    systemctl --user daemon-reload >/dev/null 2>&1 || true
    systemctl --user reset-failed "$unit" >/dev/null 2>&1 || true
    systemctl --user restart "$unit" >/dev/null 2>&1 ||
      systemctl --user start "$unit" >/dev/null 2>&1 || true
  fi

  for attempt in {1..30}; do
    if openclaw_gateway_service_active_running "$unit"; then
      wait_for_openclaw_gateway || true
      state_mark GATEWAY_SERVICE_ACTIVE
      return 0
    fi
    sleep 2
  done

  state_mark OPENCLAW_GATEWAY_RECOVERY_FAILED
  return 1
}

repair_gateway_deactivating_if_needed() {
  [[ "$RUN_CONTEXT" == agentchat_supervisor ]] || return 0
  have systemctl || return 0

  local unit active sub main_pid
  unit="$(openclaw_gateway_unit || true)"
  [[ -n "$unit" ]] || return 0

  active="$(systemctl --user show "$unit" -p ActiveState --value 2>/dev/null || true)"
  sub="$(systemctl --user show "$unit" -p SubState --value 2>/dev/null || true)"
  if [[ "$active" != deactivating && "$sub" != *deactivating* && "$sub" != stop-sigterm && "$sub" != stop-sigkill ]]; then
    return 0
  fi

  log "OpenClaw gateway unit $unit is stuck in ${active}/${sub}; repairing in background supervisor"
  timeout 20s systemctl --user stop "$unit" >/dev/null 2>&1 || true
  main_pid="$(systemctl --user show "$unit" -p MainPID --value 2>/dev/null || true)"
  if [[ "$main_pid" =~ ^[0-9]+$ && "$main_pid" -gt 0 ]]; then
    kill "$main_pid" >/dev/null 2>&1 || true
    sleep 2
    kill -9 "$main_pid" >/dev/null 2>&1 || true
  fi
  systemctl --user reset-failed "$unit" >/dev/null 2>&1 || true
  systemctl --user start "$unit" >/dev/null 2>&1 || true
}

restart_openclaw_gateway_best_effort() {
  setup_runtime_paths
  if ! have openclaw; then
    log "OpenClaw command not found; skipping gateway restart"
    return 0
  fi

  state_mark GATEWAY_RESTART_SCHEDULED
  if [[ "$RUN_CONTEXT" == agentchat_supervisor ]]; then
    state_mark AGENTCHAT_RECONNECT_EXPECTED
    sleep "${RESTART_NOTICE_DELAY_SECONDS:-4}"
  fi
  log "Restarting OpenClaw gateway"
  if timeout 90s openclaw gateway restart; then
    log "OpenClaw gateway restart requested"
  else
    log "WARNING: OpenClaw gateway restart returned non-zero; continuing to status checks"
  fi
  repair_gateway_deactivating_if_needed || true
  ensure_openclaw_gateway_service_running || {
    repair_gateway_deactivating_if_needed || true
    ensure_openclaw_gateway_service_running || true
  }
  state_mark GATEWAY_RESTART_DONE
  report_openclaw_versions || true
}

miloco_service_running() {
  setup_runtime_paths
  have miloco-cli || return 1

  local status_file="$WORK_DIR/miloco-service-running.json"
  if miloco-cli service status >"$status_file" 2>/dev/null &&
    jq -e '.running == true' "$status_file" >/dev/null 2>&1; then
    return 0
  fi

  ss -ltn 2>/dev/null | grep -Eq ':1810\b'
}

miloco_plugin_present() {
  setup_runtime_paths
  have openclaw || return 1
  openclaw plugins list 2>/dev/null | grep -qi 'miloco'
}

miloco_base_ready() {
  setup_runtime_paths
  have miloco-cli || return 1
  miloco-cli service start >/dev/null 2>&1 || true

  if ! miloco_service_running; then
    return 1
  fi

  if miloco_plugin_present; then
    state_mark MILOCO_ALREADY_INSTALLED
    state_mark MILOCO_INSTALL_DONE
    state_mark PLUGIN_READY
    return 0
  fi

  log "灯光服务已运行，灯光插件仍在确认中"
  return 1
}

sync_mimo_key_to_miloco() {
  local source_key="$MIMO_API_KEY"
  local openclaw_config="$HOME/.openclaw/openclaw.json"
  local miloco_config="$MILOCO_HOME/config.json"
  local current_key=""

  if [[ -z "$source_key" && -f "$openclaw_config" ]]; then
    source_key="$(python3 -c 'import json,sys; data=json.load(open(sys.argv[1], encoding="utf-8")); value=((((data.get("models") or {}).get("providers") or {}).get("mimo") or {}).get("apiKey", "")); print(value, end="") if isinstance(value, str) else None' "$openclaw_config" 2>/dev/null || true)"
  fi

  if [[ -z "$source_key" ]]; then
    state_mark_silent MIMO_KEY_ABSENT
    return 0
  fi

  if [[ -f "$miloco_config" ]]; then
    current_key="$(python3 -c 'import json,sys; data=json.load(open(sys.argv[1], encoding="utf-8")); value=((data.get("model") or {}).get("omni") or {}).get("api_key", ""); print(value, end="") if isinstance(value, str) else None' "$miloco_config" 2>/dev/null || true)"
  fi
  if [[ -n "$current_key" && "$current_key" == "$source_key" ]]; then
    log "MiMo Key 已配置，跳过"
    return 0
  fi

  miloco-cli config set model.omni.api_key "$source_key" --no-restart >/dev/null 2>&1 || die "MiMo Key 同步失败"
  current_key="$(python3 -c 'import json,sys; data=json.load(open(sys.argv[1], encoding="utf-8")); value=((data.get("model") or {}).get("omni") or {}).get("api_key", ""); print(value, end="") if isinstance(value, str) else None' "$miloco_config" 2>/dev/null || true)"
  [[ "$current_key" == "$source_key" ]] || die "MiMo Key 同步后校验失败"
  miloco-cli service restart >/dev/null 2>&1 || true
  log "MiMo Key 已同步"
}

install_miloco() {
  local installer="$WORK_DIR/install-miloco.sh"
  mapfile -t urls < <(miloco_installer_urls | rank_urls_by_speed "灯光插件安装器" 1)

  state_mark LIGHT_COMPONENT_DOWNLOAD_STARTED
  log "正在下载灯光插件组件"
  download_first "$installer" "${urls[@]}" || die "灯光插件安装器下载失败"
  chmod +x "$installer"

  if [[ "$PRELOAD_MILOCO_BUNDLE" == 1 ]]; then
    preload_miloco_bundle "$installer"
  fi
  state_mark LIGHT_COMPONENT_DOWNLOAD_DONE

  setup_wheelhouse_if_requested

  setup_runtime_paths

  # Redirect stdin so Miloco installer skips Mi Home and model prompts.
  state_mark LIGHT_SERVICE_INSTALL_STARTED
  state_mark MILOCO_INSTALL_STARTED
  run_miloco_phase "$installer" --agent-prepare

  if ! run_miloco_phase "$installer" --agent-finish; then
    log "WARNING: 灯光插件收尾步骤返回异常，正在确认是否已安装完成"
    if miloco_base_ready; then
      log "灯光服务和灯光插件已就绪，继续后续步骤"
    else
      die "灯光插件收尾失败，且未确认安装完成"
    fi
  fi

  miloco-cli service start >/dev/null 2>&1 || true
  state_mark MILOCO_INSTALL_DONE
  restart_openclaw_gateway_best_effort
  wait_for_miloco_service || true
  if miloco_plugin_present; then
    state_mark PLUGIN_READY
  fi
}

install_weixin_if_requested() {
  if [[ "$INSTALL_WEIXIN_PLUGIN" != 1 ]]; then
    log "Skipping WeChat plugin login. Run later with: INSTALL_ACTION=weixin RUN_SYSTEM_UPGRADE=0 bash /tmp/install-miloco-openclaw-cloud.sh"
    return
  fi

  install_personal_weixin_channel
}

install_personal_weixin_channel() {
  ensure_openclaw_command
  log "Installing WeChat channel plugin. This may prompt for QR login."
  local registry
  registry="$(select_npm_registry)"
  if [[ -n "$registry" ]]; then
    npm_config_registry="$registry" npx -y @tencent-weixin/openclaw-weixin-cli install
  else
    npx -y @tencent-weixin/openclaw-weixin-cli install
  fi
}

ensure_openclaw_command() {
  setup_runtime_paths
  have openclaw || die "OpenClaw is not installed yet. Run option 1 first."
}

run_channel_guided_setup() {
  local label="$1"
  shift
  ensure_openclaw_command
  log "Starting OpenClaw channel setup: $label"
  "$@"
}

verify_install() {
  log "灯光服务验证"
  setup_runtime_paths
  printf '脚本版本: %s\n' "$SCRIPT_VERSION"
  if have openclaw; then
    printf '龙虾环境: 已安装\n'
    if ! ensure_openclaw_gateway_service_running; then
      state_mark OPENCLAW_GATEWAY_RECOVERY_FAILED
      die "龙虾后台服务暂未恢复"
    fi
  else
    printf '龙虾环境: 未确认\n'
    die "龙虾环境暂未确认"
  fi
  if have miloco-cli; then
    local service_status_file="$WORK_DIR/light-service-status.json"
    if miloco-cli service status >"$service_status_file" 2>/dev/null &&
      jq -e '.running == true' "$service_status_file" >/dev/null 2>&1; then
      printf '灯光服务验证: 运行中\n'
    else
      printf '灯光服务验证: 已安装，等待启动确认\n'
    fi
  else
    printf '灯光服务验证: 未安装\n'
  fi
  if have openclaw && openclaw plugins list >"$WORK_DIR/openclaw-plugins.txt" 2>/dev/null; then
    if grep -qi 'miloco' "$WORK_DIR/openclaw-plugins.txt"; then
      printf '灯光插件状态: 已安装\n'
    else
      printf '灯光插件状态: 未确认\n'
    fi
  else
    printf '灯光插件状态: 暂未读取到\n'
  fi
  if [[ -f /var/run/reboot-required ]]; then
    log "系统提示后续可重启服务器以启用新内核；不影响当前安装结果。"
  fi
  df -h / | awk 'NR==1 {next} NR==2 {printf "磁盘空间: 已用 %s / 总计 %s\n", $3, $2}'
}

print_header() {
  cat <<EOF

============================================================
 馨光 AI 设计灯光安装指导
 脚本版本: $SCRIPT_VERSION
============================================================
EOF
}

print_menu_status() {
  setup_runtime_paths
  printf '\n当前状态:\n'
  if have openclaw; then
    printf '  ✓ OpenClaw: %s\n' "$(openclaw --version 2>/dev/null || printf installed)"
  else
    printf '  - OpenClaw: not installed\n'
  fi

  if have miloco-cli; then
    local miloco_state
    miloco_state="$(miloco-cli service status 2>/dev/null | jq -r '.running // false' 2>/dev/null || printf false)"
    if [[ "$miloco_state" == true ]]; then
      printf '  ✓ 灯光服务: 运行中\n'
    else
      printf '  - 灯光服务: 已安装，未运行\n'
    fi
  else
    printf '  - 灯光服务: 未安装\n'
  fi

  if have openclaw; then
    local channel_summary
    channel_summary="$(openclaw channels list --all 2>/dev/null | grep -E 'Weixin|WeCom|Feishu' || true)"
    if [[ -n "$channel_summary" ]]; then
      printf '  - Channels:\n'
      printf '%s\n' "$channel_summary" | sed 's/^/      /'
    else
      printf '  - Channels: not checked\n'
    fi
  fi
}

show_main_menu() {
  while true; do
    print_header
    print_menu_status
    cat <<'EOF'

请选择操作:
  1) 一键傻瓜式部署
     依赖检查 -> 龙虾环境检查 -> 灯光插件 -> 平台/米家绑定提示

  2) 功能模块维护
     只维护某一个模块，不从头到尾重复部署

  3) 平台绑定
     个人微信 / 企业微信 / 飞书

  4) 查看服务状态

  5) 查看安装日志

  0) 退出
EOF
    printf '\n请输入选项 [1-5,0]: '
    IFS= read -r choice || choice=0
    case "$choice" in
      1) run_full_deploy; pause_for_menu ;;
      2) show_maintenance_menu ;;
      3) show_channel_menu ;;
      4) verify_install; pause_for_menu ;;
      5) show_log_tail; pause_for_menu ;;
      0) log "Exit"; return 0 ;;
      *) printf '\n无效选项: %s\n' "$choice"; pause_for_menu ;;
    esac
  done
}

show_maintenance_menu() {
  while true; do
    print_header
    print_menu_status
    cat <<'EOF'

功能模块维护:
  1) OpenClaw 升级 / 网关配置
     显式更新 OpenClaw 并修复 gateway 配置

  2) 灯光插件安装 / 更新
     只安装或更新灯光插件和必要配置

  3) 核心模块更新 / 修复
     从状态文件继续，跳过系统大升级和 OpenClaw 主动升级

  4) 重启 OpenClaw gateway

  5) 重启灯光服务

  6) 查看模块状态

  0) 返回上级菜单
EOF
    printf '\n请输入选项 [1-6,0]: '
    local maint_choice
    IFS= read -r maint_choice || maint_choice=0
    case "$maint_choice" in
      1) run_openclaw_upgrade; pause_for_menu ;;
      2) run_miloco_deploy; pause_for_menu ;;
      3) run_repair_update; pause_for_menu ;;
      4) restart_openclaw_gateway; pause_for_menu ;;
      5) restart_miloco_service; pause_for_menu ;;
      6) verify_install; pause_for_menu ;;
      0) return 0 ;;
      *) printf '\n无效选项: %s\n' "$maint_choice"; pause_for_menu ;;
    esac
  done
}

show_channel_menu() {
  while true; do
    print_header
    cat <<'EOF'

平台绑定:
  1) 个人微信
     安装微信插件并进入扫码登录流程

  2) 企业微信
     进入 OpenClaw 官方渠道配置向导，请在向导里选择 WeCom

  3) 飞书
     进入 OpenClaw Feishu 渠道配置

  4) 查看渠道列表

  0) 返回上级菜单
EOF
    printf '\n请输入选项 [1-4,0]: '
    IFS= read -r channel_choice || channel_choice=0
    case "$channel_choice" in
      1) install_personal_weixin_channel; pause_for_menu ;;
      2) run_channel_guided_setup "企业微信 / WeCom" openclaw channels add; pause_for_menu ;;
      3) run_channel_guided_setup "飞书 / Feishu" openclaw channels add --channel feishu; pause_for_menu ;;
      4) ensure_openclaw_command; openclaw channels list --all | grep -E 'Weixin|WeCom|Feishu|Lark' || true; pause_for_menu ;;
      0) return 0 ;;
      *) printf '\n无效选项: %s\n' "$channel_choice"; pause_for_menu ;;
    esac
  done
}

restart_openclaw_gateway() {
  ensure_openclaw_command
  log "Restarting OpenClaw gateway"
  timeout 60s openclaw gateway restart || log "WARNING: OpenClaw gateway restart returned non-zero"
  wait_for_openclaw_gateway || true
}

restart_miloco_service() {
  setup_runtime_paths
  have miloco-cli || die "灯光服务尚未安装。请先执行一键傻瓜式部署或灯光插件维护。"
  log "正在重启灯光服务"
  if miloco-cli service restart >/dev/null 2>&1; then
    :
  else
    miloco-cli service stop >/dev/null 2>&1 || true
    sleep 2
    miloco-cli service start >/dev/null 2>&1 || true
  fi
  wait_for_miloco_service || true
}

pause_for_menu() {
  if [[ -t 0 ]]; then
    printf '\n按 Enter 返回菜单...'
    IFS= read -r _ || true
  fi
}

show_log_tail() {
  printf '\n安装日志: %s\n\n' "$LOG_FILE"
  tail -120 "$LOG_FILE" 2>/dev/null || true
}

with_system_upgrade_disabled() {
  local previous_upgrade="$RUN_SYSTEM_UPGRADE"
  RUN_SYSTEM_UPGRADE=0
  "$@"
  RUN_SYSTEM_UPGRADE="$previous_upgrade"
}

print_mode_summary() {
  printf '\n开始安装，请稍候。\n'
}

account_bound_known() {
  setup_runtime_paths >/dev/null 2>&1 || true
  have miloco-cli || return 1

  local status_file="$WORK_DIR/account-status.txt"
  for args in "account status" "account info" "config get account"; do
    if timeout 20s miloco-cli $args >"$status_file" 2>/dev/null && [[ -s "$status_file" ]]; then
      if grep -Eiq '"is_bound"[[:space:]]*:[[:space:]]*true|is_bound[[:space:]]*[:=][[:space:]]*true|bound[[:space:]]*[:=][[:space:]]*true|已绑定' "$status_file"; then
        return 0
      fi
    fi
  done
  return 1
}

xinguang_home_selected_known() {
  [[ -f "$HOME/xinguang-ai-light/target-home.env" ]] && return 0
  [[ -f "$HOME/wainfort-light/target-home.env" ]] && return 0
  [[ -f /tmp/xinguang-skill-install.state ]] &&
    grep -Eq 'HOME_SELECTION_SINGLE_HOME_AUTO|HOME_SWITCH_DONE|DEVICE_LIST_READY|XINGUANG_SKILL_INSTALL_DONE' /tmp/xinguang-skill-install.state
}

xinguang_skill_installed_known() {
  state_has XINGUANG_SKILL_INSTALL_DONE &&
    state_has WAINFORT_SERVER_READY &&
    state_has SKILL_INSTALL_VERIFIED &&
    return 0
  [[ -f /tmp/xinguang-skill-install.state ]] &&
    grep -q 'XINGUANG_SKILL_INSTALL_DONE' /tmp/xinguang-skill-install.state &&
    grep -q 'WAINFORT_SERVER_READY' /tmp/xinguang-skill-install.state &&
    grep -q 'SKILL_INSTALL_VERIFIED' /tmp/xinguang-skill-install.state
}

print_next_actions() {
  if xinguang_skill_installed_known; then
    cat <<'EOF'

馨光 Skill 已安装，可以开始测试灯光。

你可以说：
客厅来个马尔代夫的海边日落
EOF
  elif xinguang_home_selected_known; then
    cat <<'EOF'

下一步：
请发送「安装馨光 Skill」。
EOF
  elif account_bound_known; then
    cat <<'EOF'

米家账号绑定成功，正在检查家庭列表。
EOF
  else
    cat <<'EOF'

下一步：
请发送「绑定米家账号。绑定成功后不要自动选择家庭；如果有多个家庭，请列出家庭让我选择馨光设备所在家庭。」
EOF
  fi
}

print_step_note() {
  local text="$1"
  printf '  说明: %s\n' "$text" >&2
}

ask_yes_no() {
  local prompt="$1"
  local default="${2:-n}"
  local answer
  if [[ "$INSTALL_NONINTERACTIVE" == 1 || ! -t 0 ]]; then
    return 1
  fi
  if [[ "$default" == y ]]; then
    printf '%s [Y/n]: ' "$prompt"
  else
    printf '%s [y/N]: ' "$prompt"
  fi
  IFS= read -r answer || answer=""
  answer="${answer:-$default}"
  case "$answer" in
    y|Y|yes|YES|Yes) return 0 ;;
    *) return 1 ;;
  esac
}

prompt_openclaw_platform_binding() {
  if [[ "$INSTALL_NONINTERACTIVE" == 1 || ! -t 0 ]]; then
    cat <<'EOF'

OpenClaw 平台绑定需要人工确认或扫码，本次无人值守部署自动跳过。
后续可运行:
  bash /tmp/install-miloco-openclaw-cloud.sh
然后选择:
  3) 平台绑定
EOF
    return 0
  fi

  if ! ask_yes_no "是否现在进行 OpenClaw 平台绑定？" n; then
    cat <<'EOF'
已跳过 OpenClaw 平台绑定。
后续可从主菜单选择 3) 平台绑定。
EOF
    return 0
  fi

  cat <<'EOF'

请选择要绑定的平台:
  1) 个人微信
  2) 企业微信
  3) 飞书
  0) 跳过
EOF
  printf '\n请输入选项 [1-3,0]: '
  local choice
  IFS= read -r choice || choice=0
  case "$choice" in
    1) install_personal_weixin_channel ;;
    2) run_channel_guided_setup "企业微信 / WeCom" openclaw channels add ;;
    3) run_channel_guided_setup "飞书 / Feishu" openclaw channels add --channel feishu ;;
    0) log "Skipped OpenClaw platform binding" ;;
    *) log "Invalid platform binding option, skipped: $choice" ;;
  esac
}

prompt_mihome_binding() {
  setup_runtime_paths
  if ! have miloco-cli; then
    log "灯光服务工具未就绪，跳过米家账号绑定提示"
    return 0
  fi

  if [[ "$INSTALL_NONINTERACTIVE" == 1 || ! -t 0 ]]; then
    cat <<'EOF'

下一步：
请发送「绑定米家账号。绑定成功后不要自动选择家庭；如果有多个家庭，请列出家庭让我选择馨光设备所在家庭。」
EOF
    return 0
  fi

  if ask_yes_no "是否现在生成米家账号绑定链接？" n; then
    miloco-cli account bind || true
  else
    cat <<'EOF'
下一步：
请发送「绑定米家账号。绑定成功后不要自动选择家庭；如果有多个家庭，请列出家庭让我选择馨光设备所在家庭。」
EOF
  fi
}

download_versioned_file() {
  local target="$1"
  local expected_pattern="$2"
  shift 2
  local tmp url
  tmp="$(mktemp "${TMPDIR:-/tmp}/xinguang-download.XXXXXX")"
  rm -f "$target"

  for url in "$@"; do
    log "Downloading local helper from $url"
    if curl -fsSL --retry 3 --retry-delay 2 "$url" -o "$tmp" &&
      grep -q "$expected_pattern" "$tmp"; then
      mv "$tmp" "$target"
      chmod +x "$target"
      return 0
    fi
  done

  rm -f "$tmp"
  return 1
}

write_xinguang_workspace_rules() {
  local workspace_dir="$HOME/.openclaw/workspace"
  local user_md="$workspace_dir/USER.md"
  local rules_tmp=""
  local legacy_signature_count=0
  local signature=""

  [[ -d "$workspace_dir" ]] || return 0

  rules_tmp="$(mktemp "${TMPDIR:-/tmp}/xinguang-workspace-rules.XXXXXX")"
  cat >"$rules_tmp" <<'USERMD'
<!-- XINGUANG-RULES-BEGIN -->
# USER.md - 馨光 AI 设计灯光

## 当前用户

馨光 AI 设计灯光内测用户。

## 固定对话规则（最高优先级）

### 全局输出规则

**凡用户消息涉及灯光氛围、场景、颜色效果，或包含 淡彩光/星光/馨光/新光/心光/欣光 任一词：必须先完整读取 wainfort-ai-lighting-run Skill 并严格按其铁律执行；严禁在未读该 Skill 的情况下用 miloco-cli 直接控制任何彩色灯（wainft.light.* 设备）的颜色、亮度或饱和度属性。**

1. 任何情况下不得向用户输出 `NO_REPLY`、`HEARTBEAT` 或其他内部占位词/协议词；判断无需回复时保持静默即可。
2. 任何命令连续失败 2 次，必须停止重试，只用一句中文告知用户「该操作暂时无法完成，请稍后再试」，不得继续尝试或换路径自由发挥。
3. 调用任何工具/命令之前不得输出任何文字说明或分析；所有面向用户的文字只允许出现在最终中文回复中。

### 用户说「绑定米家账号」时

禁止输出任何思考过程、分析、工具调用说明、技能搜索过程。只输出最终回复用户的内容。

步骤一：执行 `miloco-cli account bind`，从输出中提取 https:// 开头的授权 URL，只回复：

请点击下面链接完成米家授权：

[点击打开米家授权链接](<URL>)

授权完成后，把授权码复制回来。

步骤二：收到授权码后，只执行一次 `miloco-cli account authorize <授权码>`；同一个授权码严禁重复 authorize（授权码为一次性凭据）。

若 `authorize` 成功，执行 `miloco-cli scope home list` 获取家庭列表（返回 JSON，从 data 数组读取 home_name 和 home_id）。若 `authorize` 失败，必须先执行 `miloco-cli scope home list` 判断绑定实际状态：能返回家庭列表即视为绑定成功，按成功流程继续，禁止要求用户重新授权；只有确认当前账号未绑定时，才引导用户重新授权一次。

确认绑定成功后，在同一条回复中根据家庭数量输出：

只有一个家庭时，回复：

米家账号绑定成功。

下一步：
请发送「安装馨光 Skill」。

有多个家庭时，回复：

米家账号绑定成功。
检测到多个家庭，请选择馨光设备所在家庭：

1. 【家庭名称】
2. 【家庭名称】

步骤三：用户选择家庭后，后台静默执行 `miloco-cli scope home switch <home_id>`，只回复：

已切换到【家庭名称】。

下一步：
请发送「安装馨光 Skill」。

禁止：自动选第一个家庭、显示摄像头上限、显示裸露 URL、引导查看设备、显示内部命令。

### 用户说「安装馨光 Skill」时

1. 优先执行本地命令：xinguang-install-skill
2. 如果本地命令不可用，执行：bash ~/xinguang-ai-light/install-xinguang-ai-skill.sh
3. 只显示：

正在安装馨光 Skill，大约需要 2 分钟，请耐心等待。
安装完成后会自动通知您，请勿重复发送消息。

4. 安装成功后只回复：

馨光 Skill 已安装，可以开始测试灯光。

你可以说：
客厅来个马尔代夫的海边日落

5. 当安装输出含「检测到多个家庭」时：

- 如果本次对话已经知道用户选择的家庭，不要重复询问；后台静默执行 `xinguang-set-home "<家庭名称>" "<家庭ID>"`，然后重新执行安装。
- 如果尚不知道用户选择，从输出中提取家庭列表，请用户选择；收到选择后按上一步后台静默设置家庭并重新执行安装。
- 重跑后按本规则中的成功或失败回复。
- 禁止自动选择第一个家庭、解释内部要求、显示内部命令、家庭 ID 或其他内部信息。

6. 安装命令超时或被中断时，不得仅凭目录存在判断成功；必须后台静默执行 `xinguang-install-skill status` 查询状态，再按查询结果回复。

7. 全程只向用户输出中文结果；禁止输出英文推理、内部命令或 `STATE` 行。

8. 禁止：搜索 ClawHub、询问 Skill 来源、新建 Skill、推荐普通米家灯控。

9. 安装失败后只回复：

馨光 Skill 暂时无法安装，请联系工作人员处理。
<!-- XINGUANG-RULES-END -->
USERMD

  if [[ ! -e "$user_md" ]]; then
    if ! cat "$rules_tmp" >"$user_md"; then
      rm -f "$rules_tmp"
      return 1
    fi
  elif grep -Fqx '<!-- XINGUANG-RULES-BEGIN -->' "$user_md" &&
    grep -Fqx '<!-- XINGUANG-RULES-END -->' "$user_md"; then
    if ! python3 - "$user_md" "$rules_tmp" <<'PY'
import os
import stat
import sys
import tempfile
from pathlib import Path


path = Path(sys.argv[1])
replacement = Path(sys.argv[2]).read_bytes()
if replacement.endswith(b"\n"):
    replacement = replacement[:-1]
source = path.read_bytes()
begin = b"<!-- XINGUANG-RULES-BEGIN -->"
end = b"<!-- XINGUANG-RULES-END -->"

if source.count(begin) != 1 or source.count(end) != 1:
    raise SystemExit(1)

start = source.find(begin)
end_position = source.find(end, start) + len(end)
updated = source[:start] + replacement + source[end_position:]
mode = stat.S_IMODE(path.stat().st_mode)
descriptor, temporary_name = tempfile.mkstemp(prefix=".USER.md.", dir=str(path.parent))
try:
    with os.fdopen(descriptor, "wb") as temporary_file:
        temporary_file.write(updated)
        temporary_file.flush()
        os.fsync(temporary_file.fileno())
    os.chmod(temporary_name, mode)
    os.replace(temporary_name, path)
except OSError:
    try:
        os.unlink(temporary_name)
    except OSError:
        pass
    raise
PY
    then
      rm -f "$rules_tmp"
      return 1
    fi
  else
    for signature in \
      '必须先完整读取 wainfort-ai-lighting-run Skill 并严格按其铁律执行' \
      '检测到多个家庭，请选择馨光设备所在家庭：' \
      '馨光 Skill 暂时无法安装，请联系工作人员处理。'; do
      if grep -Fq -- "$signature" "$user_md"; then
        ((legacy_signature_count += 1))
      fi
    done
    if (( legacy_signature_count >= 3 )); then
      if ! cat "$rules_tmp" >"$user_md"; then
        rm -f "$rules_tmp"
        return 1
      fi
    else
      if [[ -s "$user_md" ]] && [[ "$(tail -c 1 "$user_md" 2>/dev/null || true)" != $'\n' ]]; then
        if ! printf '\n' >>"$user_md"; then
          rm -f "$rules_tmp"
          return 1
        fi
      fi
      if ! printf '\n' >>"$user_md" || ! cat "$rules_tmp" >>"$user_md"; then
        rm -f "$rules_tmp"
        return 1
      fi
      log "共存模式：已追加馨光规则，未改动您的既有配置"
    fi
  fi

  rm -f "$rules_tmp"
  log "馨光对话规则已写入龙虾工作区"
}

prepare_xinguang_set_chat_model_helper() {
  local install_dir="$XINGUANG_LOCAL_INSTALL_DIR"
  local bin_dir="$HOME/.local/bin"
  local chat_model_shortcut="$install_dir/xinguang-set-chat-model"
  local path_chat_model_shortcut="$bin_dir/xinguang-set-chat-model"

  mkdir -p "$install_dir" "$bin_dir"

  cat >"$chat_model_shortcut" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
set +x

provider="${1:-}"
api_key="${2:-}"
model_id="${3:-deepseek-chat}"

if [[ -z "$provider" || -z "$api_key" ]]; then
  printf '用法：xinguang-set-chat-model deepseek <API_KEY> [model_id]\n' >&2
  exit 1
fi

if [[ "$provider" != "deepseek" ]]; then
  printf '当前仅支持 DeepSeek 对话模型。\n' >&2
  exit 1
fi

DEEPSEEK_CONFIG_API_KEY="$api_key" python3 - "$model_id" <<'PY'
import json
import os
import shutil
import stat
import sys
import tempfile
from pathlib import Path


def fail(message):
    print(message, file=sys.stderr)
    raise SystemExit(1)


api_key = os.environ.pop("DEEPSEEK_CONFIG_API_KEY", "")
model_id = sys.argv[1]
config_path = Path.home() / ".openclaw" / "openclaw.json"
backup_path = config_path.with_name("openclaw.json.bak-chat-model")

if not api_key:
    fail("未提供 DeepSeek Key，未修改配置。")
if not config_path.is_file():
    fail("未找到龙虾配置文件，请先完成基础安装。")

try:
    with config_path.open("r", encoding="utf-8") as config_file:
        config = json.load(config_file)
except (OSError, json.JSONDecodeError):
    fail("龙虾配置文件格式错误，未修改。")

if not isinstance(config, dict):
    fail("龙虾配置文件格式错误，未修改。")

models = config.setdefault("models", {})
if not isinstance(models, dict):
    fail("龙虾配置文件格式错误，未修改。")
providers = models.setdefault("providers", {})
if not isinstance(providers, dict):
    fail("龙虾配置文件格式错误，未修改。")
agents = config.setdefault("agents", {})
if not isinstance(agents, dict):
    fail("龙虾配置文件格式错误，未修改。")
defaults = agents.setdefault("defaults", {})
if not isinstance(defaults, dict):
    fail("龙虾配置文件格式错误，未修改。")

if not backup_path.exists():
    try:
        shutil.copy2(config_path, backup_path)
    except OSError:
        fail("龙虾配置备份失败，未修改。")

providers["deepseek"] = {
    "baseUrl": "https://api.deepseek.com/v1",
    "api": "openai-completions",
    "apiKey": api_key,
    "models": [{"id": model_id, "name": model_id}],
}
defaults["model"] = {"primary": f"deepseek/{model_id}"}

try:
    source_mode = stat.S_IMODE(config_path.stat().st_mode)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=".openclaw.json.", dir=str(config_path.parent)
    )
    with os.fdopen(descriptor, "w", encoding="utf-8") as temporary_file:
        json.dump(config, temporary_file, ensure_ascii=False, indent=2)
        temporary_file.write("\n")
        temporary_file.flush()
        os.fsync(temporary_file.fileno())
    os.chmod(temporary_name, source_mode)
    os.replace(temporary_name, config_path)
except OSError:
    try:
        os.unlink(temporary_name)
    except (NameError, OSError):
        pass
    fail("龙虾配置写入失败，未修改。")
PY
unset api_key

if ! bash -lc "openclaw gateway restart" >/dev/null 2>&1; then
  printf '龙虾服务重启失败，请联系工作人员处理。\n' >&2
  exit 1
fi

printf '已将对话模型设置为 DeepSeek。\n'
EOF
  chmod +x "$chat_model_shortcut"
  cp "$chat_model_shortcut" "$path_chat_model_shortcut" 2>/dev/null || true
}

configure_deepseek_chat_model_if_requested() {
  [[ -n "$DEEPSEEK_API_KEY" ]] || return 0

  local chat_model_shortcut="$XINGUANG_LOCAL_INSTALL_DIR/xinguang-set-chat-model"
  if [[ ! -x "$chat_model_shortcut" ]]; then
    prepare_xinguang_set_chat_model_helper
  fi

  "$chat_model_shortcut" deepseek "$DEEPSEEK_API_KEY"
  printf '对话模型已配置为 DeepSeek\n'
}

write_xinguang_cron_guard_systemd_unit() {
  local source_file="$1"
  local target_file="$2"

  if sudo cmp -s "$source_file" "$target_file" 2>/dev/null; then
    return 0
  fi
  sudo install -m 0644 "$source_file" "$target_file" >/dev/null 2>&1
}

configure_xinguang_cron_guard_schedule() {
  local guard_script="$1"
  local service_tmp=""
  local timer_tmp=""
  local cron_line current_crontab

  if have sudo && sudo -n true >/dev/null 2>&1; then
    service_tmp="$(mktemp "${TMPDIR:-/tmp}/xinguang-cron-guard.service.XXXXXX")"
    timer_tmp="$(mktemp "${TMPDIR:-/tmp}/xinguang-cron-guard.timer.XXXXXX")"

    cat >"$service_tmp" <<EOF
[Unit]
Description=馨光 Miloco 后台模型任务看门狗

[Service]
Type=oneshot
User=ubuntu
ExecStart=/bin/bash -lc '$guard_script'
EOF

    cat >"$timer_tmp" <<'EOF'
[Unit]
Description=馨光 Miloco 后台模型任务看门狗定时器

[Timer]
OnBootSec=2min
OnUnitActiveSec=10min
Persistent=true
Unit=xinguang-cron-guard.service

[Install]
WantedBy=timers.target
EOF

    if write_xinguang_cron_guard_systemd_unit "$service_tmp" /etc/systemd/system/xinguang-cron-guard.service &&
      write_xinguang_cron_guard_systemd_unit "$timer_tmp" /etc/systemd/system/xinguang-cron-guard.timer &&
      sudo systemctl daemon-reload >/dev/null 2>&1 &&
      sudo systemctl enable --now xinguang-cron-guard.timer >/dev/null 2>&1; then
      rm -f "$service_tmp" "$timer_tmp"
      return 0
    fi

    rm -f "$service_tmp" "$timer_tmp"
    log "系统定时器配置失败，改用用户定时任务。"
  fi

  have crontab || {
    log "无法写入用户定时任务，请联系工作人员处理。"
    return 1
  }

  cron_line="*/10 * * * * /bin/bash -lc '$guard_script'"
  current_crontab="$(crontab -l 2>/dev/null || true)"
  if ! grep -Fqx "$cron_line" <<<"$current_crontab"; then
    if ! {
      printf '%s\n' "$current_crontab"
      printf '%s\n' "$cron_line"
    } | crontab - >/dev/null 2>&1; then
      log "无法写入用户定时任务，请联系工作人员处理。"
      return 1
    fi
  fi
}

disable_xinguang_cron_guard_schedule() {
  local install_dir="$XINGUANG_LOCAL_INSTALL_DIR"
  local guard_script="$install_dir/xinguang-cron-guard"
  local cron_line current_crontab

  if have sudo && sudo -n true >/dev/null 2>&1; then
    if sudo systemctl list-unit-files xinguang-cron-guard.timer --no-legend 2>/dev/null |
      grep -q '^xinguang-cron-guard\.timer'; then
      if ! sudo systemctl disable --now xinguang-cron-guard.timer >/dev/null 2>&1; then
        log "无法停用已有的馨光看门狗定时器，请联系工作人员处理。"
        return 1
      fi
    fi
  elif [[ -e /etc/systemd/system/xinguang-cron-guard.timer ]]; then
    log "无法停用已有的馨光看门狗定时器，请联系工作人员处理。"
    return 1
  fi

  have crontab || return 0

  cron_line="*/10 * * * * /bin/bash -lc '$guard_script'"
  current_crontab="$(crontab -l 2>/dev/null || true)"
  if grep -Fqx "$cron_line" <<<"$current_crontab"; then
    if ! printf '%s\n' "$current_crontab" |
      awk -v guard_line="$cron_line" '$0 != guard_line' |
      crontab - >/dev/null 2>&1; then
      log "无法停用已有的馨光看门狗定时任务，请联系工作人员处理。"
      return 1
    fi
  fi
}

miloco_omni_model_is_configured() {
  local config_file="$HOME/.openclaw/miloco/config.json"

  [[ -f "$config_file" ]] || return 1

  python3 - "$config_file" <<'PY'
import json
import sys


try:
    with open(sys.argv[1], encoding="utf-8") as config_file:
        config = json.load(config_file)
except (OSError, json.JSONDecodeError):
    raise SystemExit(1)

model = config.get("model") if isinstance(config, dict) else None
omni = model.get("omni") if isinstance(model, dict) else None
api_key = omni.get("api_key") if isinstance(omni, dict) else None
raise SystemExit(0 if isinstance(api_key, str) and api_key.strip() else 1)
PY
}

prepare_xinguang_cron_guard() {
  case "$XINGUANG_KEEP_MILOCO_CRON" in
    1)
      disable_xinguang_cron_guard_schedule || return 1
      log "已按 XINGUANG_KEEP_MILOCO_CRON=1 强制保留 Miloco 后台任务，跳过看门狗。"
      return 0
      ;;
    0)
      log "已按 XINGUANG_KEEP_MILOCO_CRON=0 强制关闭 Miloco 后台任务。"
      ;;
    "")
      if miloco_omni_model_is_configured; then
        disable_xinguang_cron_guard_schedule || return 1
        log "检测到 Miloco 已配置模型（感知功能使用中），保留其后台任务"
        return 0
      fi
      ;;
    *)
      disable_xinguang_cron_guard_schedule || return 1
      log "XINGUANG_KEEP_MILOCO_CRON 仅支持 0 或 1；为避免影响现有任务，保留其后台任务。"
      return 0
      ;;
  esac

  local install_dir="$XINGUANG_LOCAL_INSTALL_DIR"
  local bin_dir="$HOME/.local/bin"
  local guard_script="$install_dir/xinguang-cron-guard"
  local path_guard_script="$bin_dir/xinguang-cron-guard"

  mkdir -p "$install_dir" "$bin_dir"

  cat >"$guard_script" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

# 非登录环境需要显式加入 pnpm 与 nvm 的 Node 路径。
export PATH="$HOME/.local/share/pnpm:$HOME/.npm-global/bin:$PATH"
for node_bin in "$HOME"/.nvm/versions/node/*/bin; do
  [[ -d "$node_bin" ]] || continue
  export PATH="$node_bin:$PATH"
done

bash -lc '
  set -Eeuo pipefail
  export PATH="$HOME/.local/share/pnpm:$HOME/.npm-global/bin:$PATH"
  for node_bin in "$HOME"/.nvm/versions/node/*/bin; do
    [[ -d "$node_bin" ]] || continue
    export PATH="$node_bin:$PATH"
  done

  command -v openclaw >/dev/null 2>&1 || exit 0
  while IFS= read -r cron_id; do
    [[ -n "$cron_id" ]] || continue
    openclaw cron disable "$cron_id" >/dev/null 2>&1 || true
  done < <(openclaw cron list 2>/dev/null | grep "miloco-" | awk "{print \$1}" || true)
'
EOF
  chmod +x "$guard_script"
  cp "$guard_script" "$path_guard_script" 2>/dev/null || true

  "$guard_script"
  printf '已关闭 Miloco 后台模型任务（馨光专用模式）；如需视觉感知功能请联系工作人员开启\n'
  configure_xinguang_cron_guard_schedule "$guard_script"
}

prepare_xinguang_skill_installer() {
  local install_dir="$XINGUANG_LOCAL_INSTALL_DIR"
  local bin_dir="$HOME/.local/bin"
  local entry="$install_dir/install-xinguang-ai-skill.sh"
  local main="$install_dir/install-xinguang-skill.sh"
  local shortcut="$install_dir/xinguang-install-skill"
  local home_shortcut="$install_dir/xinguang-set-home"
  local path_shortcut="$bin_dir/xinguang-install-skill"
  local path_home_shortcut="$bin_dir/xinguang-set-home"

  mkdir -p "$install_dir" "$bin_dir"

  download_versioned_file "$entry" "ENTRY_VERSION=\"$XINGUANG_SKILL_ENTRY_VERSION\"" \
    "https://nijez.github.io/xingguang-ai-lighting-guide/install-xinguang-ai-skill.sh" \
    "https://raw.githubusercontent.com/nijez/xingguang-ai-lighting-guide/main/install-xinguang-ai-skill.sh" \
    "https://cdn.jsdelivr.net/gh/nijez/xingguang-ai-lighting-guide@main/install-xinguang-ai-skill.sh" ||
    die

  download_versioned_file "$main" "XINGUANG_SKILL_INSTALLER_VERSION=\"$XINGUANG_SKILL_INSTALLER_VERSION\"" \
    "https://nijez.github.io/xingguang-ai-lighting-guide/install-xinguang-skill.sh" \
    "https://raw.githubusercontent.com/nijez/xingguang-ai-lighting-guide/main/install-xinguang-skill.sh" \
    "https://cdn.jsdelivr.net/gh/nijez/xingguang-ai-lighting-guide@main/install-xinguang-skill.sh" ||
    die

  cat >"$shortcut" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
config="$install_dir/target-home.env"
if [[ -f "\$config" ]]; then
  set -a
  # shellcheck disable=SC1090
  . "\$config"
  set +a
fi
action="\${1:-install}"
case "\$action" in
  status|progress)
    TARGET="$main" INSTALL_ACTION=status INSTALL_NONINTERACTIVE=1 bash "$entry" status
    ;;
  *)
    TARGET="$main" INSTALL_ACTION=continue INSTALL_NONINTERACTIVE=1 bash "$entry"
    ;;
esac
EOF
  chmod +x "$shortcut"
  cp "$shortcut" "$path_shortcut" 2>/dev/null || true

  cat >"$home_shortcut" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
base="$HOME/xinguang-ai-light"
mkdir -p "$base"
home_name="${1:-}"
home_id="${2:-}"
if [[ -z "$home_name" ]]; then
  printf '请选择馨光设备所在家庭。\n' >&2
  exit 1
fi
umask 077
{
  printf 'XINGUANG_TARGET_HOME=%q\n' "$home_name"
  printf 'XINGUANG_TARGET_HOME_ID=%q\n' "$home_id"
} >"$base/target-home.env"
chmod 600 "$base/target-home.env" 2>/dev/null || true
EOF
  chmod +x "$home_shortcut"
  cp "$home_shortcut" "$path_home_shortcut" 2>/dev/null || true

  state_mark XINGUANG_SKILL_INSTALLER_READY

  cat >"$install_dir/灯光测试提示.txt" <<'EOF'
米家账号绑定并选择家庭后，请发送「安装馨光 Skill」。
馨光 Skill 安装完成后，可以测试灯光：
客厅来个马尔代夫的海边日落
EOF
}

prepare_xinguang_panel() {
  local install_dir bin_dir panel path_panel
  install_dir="$XINGUANG_LOCAL_INSTALL_DIR"
  bin_dir="$HOME/.local/bin"
  panel="$install_dir/xinguang"
  path_panel="$bin_dir/xinguang"

  mkdir -p "$install_dir" "$bin_dir"

  download_versioned_file "$panel" "XINGUANG_PANEL_VERSION=\"$XINGUANG_PANEL_VERSION\"" \
    "https://nijez.github.io/xingguang-ai-lighting-guide/xinguang-panel.sh" \
    "https://raw.githubusercontent.com/nijez/xingguang-ai-lighting-guide/main/xinguang-panel.sh" \
    "https://cdn.jsdelivr.net/gh/nijez/xingguang-ai-lighting-guide@main/xinguang-panel.sh" ||
    die

  cp "$panel" "$path_panel" || die
  chmod +x "$panel" "$path_panel"
}

prepare_xinguang_show() {
  local install_dir bin_dir show path_show show_dir show_data show_header
  install_dir="$XINGUANG_LOCAL_INSTALL_DIR"
  bin_dir="$HOME/.local/bin"
  show="$install_dir/xinguang-show"
  path_show="$bin_dir/xinguang-show"
  show_dir="$install_dir/shows"
  show_data="$show_dir/chuantongse.show"

  mkdir -p "$install_dir" "$bin_dir" "$show_dir"

  download_versioned_file "$show" "XINGUANG_SHOW_VERSION=\"$XINGUANG_SHOW_VERSION\"" \
    "https://nijez.github.io/xingguang-ai-lighting-guide/xinguang-show.sh" \
    "https://raw.githubusercontent.com/nijez/xingguang-ai-lighting-guide/main/xinguang-show.sh" \
    "https://cdn.jsdelivr.net/gh/nijez/xingguang-ai-lighting-guide@main/xinguang-show.sh" ||
    die

  cp "$show" "$path_show" || die
  chmod +x "$show" "$path_show"

  show_header="$(printf '#秀名\t中国传统色十景')"
  download_versioned_file "$show_data" "$show_header" \
    "https://nijez.github.io/xingguang-ai-lighting-guide/shows/chuantongse.show" \
    "https://raw.githubusercontent.com/nijez/xingguang-ai-lighting-guide/main/shows/chuantongse.show" \
    "https://cdn.jsdelivr.net/gh/nijez/xingguang-ai-lighting-guide@main/shows/chuantongse.show" ||
    die
}

run_full_deploy() {
  local step_start
  TOTAL_STEPS=6
  state_init
  state_mark_silent INSTALL_STARTED
  print_mode_summary "full"
  log "Starting Xingguang AI lighting install (script $SCRIPT_VERSION)"
  log "Install started at: $(date -Is)"

  if state_has STEP_1_DONE; then
    step_skip_msg 1 "Base packages check" "state already has STEP_1_DONE"
  else
    step_start="$(date +%s)"
    step_start_msg 1 "Base packages check"
    print_step_note "只执行 apt update 和缺失依赖安装；默认不做系统全量升级、不升级新内核。"
    apt_bootstrap
    step_done_msg 1 "Base packages check" "$step_start"
    log_timing_since "Ubuntu packages" "$step_start"
  fi

  if state_has STEP_2_DONE; then
    step_skip_msg 2 "OpenClaw check and gateway config" "state already has STEP_2_DONE"
  else
    step_start="$(date +%s)"
    step_start_msg 2 "OpenClaw check and gateway config"
    print_step_note "默认面向腾讯云 OpenClaw 应用模板：已安装且满足最低兼容版本时跳过升级；低于最低兼容版本或 OPENCLAW_UPDATE=1 时才升级。"
    install_openclaw
    step_done_msg 2 "OpenClaw check and gateway config" "$step_start"
    log_timing_since "OpenClaw" "$step_start"
  fi

  if state_has STEP_3_DONE; then
    step_skip_msg 3 "安装灯光插件" "state already has STEP_3_DONE"
  else
    step_start="$(date +%s)"
    step_start_msg 3 "安装灯光插件"
    print_step_note "正在下载灯光插件组件，安装灯光服务和项目必要插件；不默认安装额外平台插件。"
    if miloco_base_ready; then
      log "灯光服务和灯光插件已就绪，无需重复安装"
      restart_openclaw_gateway_best_effort
    else
      install_miloco
    fi
    step_done_msg 3 "安装灯光插件" "$step_start"
    log_timing_since "灯光插件" "$step_start"
  fi
  sync_mimo_key_to_miloco

  if state_has STEP_4_DONE; then
    step_skip_msg 4 "Ask OpenClaw platform binding" "state already has STEP_4_DONE"
  else
    step_start="$(date +%s)"
    step_start_msg 4 "Ask OpenClaw platform binding"
    print_step_note "默认跳过个人微信、企业微信和飞书绑定；后续需要时可从菜单进入。"
    prompt_openclaw_platform_binding
    step_done_msg 4 "Ask OpenClaw platform binding" "$step_start"
    log_timing_since "OpenClaw platform binding prompt" "$step_start"
  fi

  if state_has STEP_5_DONE; then
    step_skip_msg 5 "米家账号绑定提示" "state already has STEP_5_DONE"
  else
    step_start="$(date +%s)"
    step_start_msg 5 "米家账号绑定提示"
    print_step_note "预置馨光 Skill 本地安装器，并提示后续绑定米家账号。"
    prepare_xinguang_skill_installer
    prompt_mihome_binding
    step_done_msg 5 "米家账号绑定提示" "$step_start"
    log_timing_since "米家账号绑定提示" "$step_start"
  fi

  prepare_xinguang_panel
  prepare_xinguang_show
  prepare_xinguang_set_chat_model_helper
  configure_deepseek_chat_model_if_requested

  if state_has STEP_6_DONE; then
    step_skip_msg 6 "灯光服务验证和下一步引导" "state already has STEP_6_DONE"
  else
    step_start="$(date +%s)"
    step_start_msg 6 "灯光服务验证和下一步引导"
    print_step_note "检查灯光服务、龙虾后台服务和灯光插件状态。"
    restart_openclaw_gateway_best_effort
    verify_install
    log "Done"
    log_timing_since "Total install" "$SCRIPT_START_EPOCH"
    if state_has AGENTCHAT_RECONNECT_EXPECTED; then
      state_mark SUCCESS_AFTER_RECONNECT
    else
      state_mark SUCCESS_ACTIVE
    fi
    step_done_msg 6 "灯光服务验证和下一步引导" "$step_start"
  fi

  write_xinguang_workspace_rules || log "警告：馨光对话规则写入失败，不影响主流程"
  prepare_xinguang_cron_guard
  print_next_actions
}

run_openclaw_upgrade() {
  local step_start action_start previous_update
  TOTAL_STEPS=3
  action_start="$(date +%s)"
  previous_update="$OPENCLAW_UPDATE"
  OPENCLAW_UPDATE=1
  print_mode_summary "openclaw"

  step_start="$(date +%s)"
  step_start_msg 1 "Base packages check"
  with_system_upgrade_disabled apt_bootstrap
  step_done_msg 1 "Base packages check" "$step_start"

  step_start="$(date +%s)"
  step_start_msg 2 "OpenClaw update and gateway config"
  install_openclaw
  step_done_msg 2 "OpenClaw update and gateway config" "$step_start"

  step_start="$(date +%s)"
  step_start_msg 3 "灯光服务验证"
  verify_install
  step_done_msg 3 "灯光服务验证" "$step_start"
  log_timing_since "OpenClaw action" "$action_start"
  OPENCLAW_UPDATE="$previous_update"
}

run_miloco_deploy() {
  local step_start action_start previous_update
  TOTAL_STEPS=4
  action_start="$(date +%s)"
  print_mode_summary "灯光插件维护"

  step_start="$(date +%s)"
  step_start_msg 1 "Base packages check"
  with_system_upgrade_disabled apt_bootstrap
  step_done_msg 1 "Base packages check" "$step_start"

  step_start="$(date +%s)"
  step_start_msg 2 "OpenClaw gateway check"
  previous_update="$OPENCLAW_UPDATE"
  OPENCLAW_UPDATE=auto
  install_openclaw
  OPENCLAW_UPDATE="$previous_update"
  step_done_msg 2 "OpenClaw gateway check" "$step_start"

  step_start="$(date +%s)"
  step_start_msg 3 "安装或更新灯光插件"
  if miloco_base_ready; then
    log "灯光服务和灯光插件已就绪，跳过重复安装"
    restart_openclaw_gateway_best_effort
  else
    install_miloco
  fi
  sync_mimo_key_to_miloco
  step_done_msg 3 "安装或更新灯光插件" "$step_start"

  step_start="$(date +%s)"
  step_start_msg 4 "灯光服务验证"
  restart_openclaw_gateway_best_effort
  verify_install
  if state_has AGENTCHAT_RECONNECT_EXPECTED; then
    state_mark SUCCESS_AFTER_RECONNECT
  else
    state_mark SUCCESS_ACTIVE
  fi
  step_done_msg 4 "灯光服务验证" "$step_start"
  log_timing_since "灯光插件维护" "$action_start"
  write_xinguang_workspace_rules || log "警告：馨光对话规则写入失败，不影响主流程"
  print_next_actions
}

run_repair_update() {
  local previous_upgrade previous_update previous_extra
  previous_upgrade="$RUN_SYSTEM_UPGRADE"
  previous_update="$OPENCLAW_UPDATE"
  previous_extra="$INSTALL_EXTRA_PLUGINS"
  RUN_SYSTEM_UPGRADE=0
  OPENCLAW_UPDATE=auto
  INSTALL_EXTRA_PLUGINS=0
  run_full_deploy
  RUN_SYSTEM_UPGRADE="$previous_upgrade"
  OPENCLAW_UPDATE="$previous_update"
  INSTALL_EXTRA_PLUGINS="$previous_extra"
}

run_continue_deploy() {
  run_repair_update
}

run_status_report() {
  state_init
  if [[ "${RUN_CONTEXT:-}" == terminal* ]]; then
    terminal_status_report
    return
  fi

  if install_complete_state; then
    status_complete_message
  elif state_has GATEWAY_RESTART_SCHEDULED || state_has AGENTCHAT_RECONNECT_EXPECTED; then
    status_restart_message
  elif state_has STEP_3_DONE || state_has STEP_4_STARTED || state_has STEP_4_DONE || state_has STEP_5_STARTED || state_has STEP_5_DONE || state_has STEP_6_STARTED || state_has GATEWAY_RESTART_DONE; then
    printf '当前进度：\n3/4 正在准备米家连接\n'
    status_running_hint
  elif state_has STEP_2_DONE || state_has STEP_3_STARTED || state_has PLUGIN_READY; then
    printf '当前进度：\n2/4 正在安装灯光插件\n'
    status_running_hint
  elif state_has STEP_1_STARTED || state_has STEP_1_DONE || state_has STEP_2_STARTED; then
    printf '当前进度：\n1/4 正在准备安装环境\n'
    status_running_hint
  else
    printf '当前进度：\n1/4 正在准备安装环境\n'
    status_running_hint
  fi
}

dispatch_action() {
  case "$1" in
    menu) show_main_menu ;;
    full|install) run_full_deploy ;;
    openclaw|upgrade-openclaw) run_openclaw_upgrade ;;
    miloco|install-miloco|miloco-only) run_miloco_deploy ;;
    repair|update|fix) run_repair_update ;;
    continue|resume) run_continue_deploy ;;
    restart-openclaw) restart_openclaw_gateway ;;
    restart-miloco) restart_miloco_service ;;
    weixin|wechat)
      INSTALL_WEIXIN_PLUGIN=1
      install_personal_weixin_channel
      ;;
    status) run_status_report ;;
    logs|log) show_log_tail ;;
    *)
      die "Unknown INSTALL_ACTION: $1 (use menu|full|continue|openclaw|miloco|miloco-only|repair|restart-openclaw|restart-miloco|weixin|status|logs)"
      ;;
  esac
}

main() {
  require_ubuntu

  case "${1:-}" in
    --menu|menu) INSTALL_ACTION=menu ;;
    --full|full|install) INSTALL_ACTION=full ;;
    --openclaw|openclaw|upgrade-openclaw) INSTALL_ACTION=openclaw ;;
    --miloco|miloco|install-miloco|miloco-only) INSTALL_ACTION=miloco ;;
    --repair|repair|update|fix) INSTALL_ACTION=repair ;;
    --continue|continue|resume) INSTALL_ACTION=continue ;;
    --restart-openclaw|restart-openclaw) INSTALL_ACTION=restart-openclaw ;;
    --restart-miloco|restart-miloco) INSTALL_ACTION=restart-miloco ;;
    --weixin|weixin|wechat) INSTALL_ACTION=weixin ;;
    --status|status) INSTALL_ACTION=status ;;
    --logs|logs|log) INSTALL_ACTION=logs ;;
    "") ;;
    *) die "Unknown argument: $1" ;;
  esac

  if [[ -z "$INSTALL_ACTION" ]]; then
    if [[ -t 0 ]]; then
      INSTALL_ACTION=menu
    else
      INSTALL_ACTION=full
    fi
  fi

  if [[ "$DEPLOY_SUPERVISOR" == 1 && "$RUN_CONTEXT" != agentchat_supervisor ]]; then
    case "$INSTALL_ACTION" in
      full|install|continue|resume|repair|update|fix)
        launch_background_supervisor
        return 0
        ;;
    esac
  fi

  if [[ "$RUN_CONTEXT" == agentchat_supervisor ]]; then
    state_mark BACKGROUND_SUPERVISOR_STARTED
  fi

  dispatch_action "$INSTALL_ACTION"
}

main "$@"
