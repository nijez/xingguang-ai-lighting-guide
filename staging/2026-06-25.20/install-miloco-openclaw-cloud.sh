#!/usr/bin/env bash
set -Eeuo pipefail

# One-shot OpenClaw + Xiaomi Miloco installer for a Tencent Cloud OpenClaw app-template VM.
# Defaults are intentionally conservative:
# - OpenClaw gateway binds to loopback only.
# - Mi Home account binding is skipped.
# - WeChat channel installation/login is skipped.
# - MiMo API key is configured only when MIMO_API_KEY is supplied.

SCRIPT_VERSION="2026-06-25.20"
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
LOG_FILE="${LOG_FILE:-$HOME/miloco-cloud-install.log}"
STATE_FILE="${STATE_FILE:-/tmp/openclaw-miloco-install.state}"
XINGUANG_SKILL_ENTRY_VERSION="${XINGUANG_SKILL_ENTRY_VERSION:-2026-06-26.9}"
XINGUANG_SKILL_INSTALLER_VERSION="${XINGUANG_SKILL_INSTALLER_VERSION:-2026-06-26.9}"
XINGUANG_LOCAL_INSTALL_DIR="${XINGUANG_LOCAL_INSTALL_DIR:-$HOME/xinguang-ai-light}"

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
  if state_has STEP_6_DONE || state_has SUCCESS_ACTIVE || state_has SUCCESS_AFTER_RECONNECT; then
    return 0
  fi
  state_mark EXITED_BUT_INCOMPLETE || true
  cat >&2 <<EOF

安装暂时无法继续，请联系工作人员处理。
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
    printf 'export XINGUANG_SKILL_ENTRY_VERSION=%q\n' "$XINGUANG_SKILL_ENTRY_VERSION"
    printf 'export XINGUANG_SKILL_INSTALLER_VERSION=%q\n' "$XINGUANG_SKILL_INSTALLER_VERSION"
    printf 'export XINGUANG_LOCAL_INSTALL_DIR=%q\n' "$XINGUANG_LOCAL_INSTALL_DIR"
    printf 'exec bash %q\n' "$script"
  } >"$launcher"
  chmod +x "$launcher"
}

terminal_progress_message_for_marker() {
  case "$1" in
    STEP_1_STARTED)
      printf '[10%%] 正在检查系统环境...\n'
      ;;
    STEP_1_DONE)
      printf '[20%%] 正在准备必要依赖...\n'
      ;;
    STEP_2_STARTED)
      printf '[30%%] 正在检查龙虾环境...\n'
      ;;
    STEP_2_DONE)
      printf '[40%%] 正在更新龙虾环境...\n'
      ;;
    STEP_3_STARTED)
      printf '[50%%] 正在安装灯光连接组件...\n'
      ;;
    LIGHT_COMPONENT_DOWNLOAD_STARTED)
      printf '[60%%] 正在下载灯光组件...\n'
      ;;
    LIGHT_SERVICE_INSTALL_STARTED|LIGHT_COMPONENT_DOWNLOAD_DONE|MILOCO_INSTALL_STARTED)
      printf '[70%%] 正在安装灯光服务...\n'
      ;;
    STEP_3_DONE)
      printf '[75%%] 正在准备米家连接...\n'
      ;;
    STEP_4_STARTED|STEP_4_DONE|STEP_5_STARTED)
      printf '[75%%] 正在准备米家连接...\n'
      ;;
    XINGUANG_SKILL_PREINSTALL_STARTED|XINGUANG_SKILL_INSTALL_DONE|XINGUANG_SKILL_PREINSTALL_DONE|STEP_5_DONE)
      printf '[80%%] 正在安装馨光 Skill...\n'
      ;;
    STEP_6_STARTED|GATEWAY_RESTART_DONE)
      printf '[90%%] 正在验证安装结果...\n'
      ;;
    STEP_6_DONE|SUCCESS_ACTIVE|SUCCESS_AFTER_RECONNECT)
      printf '[100%%] 安装完成。\n\n下一步：\n请回到龙虾，发送「绑定米家账号」。\n'
      ;;
    ERROR:*|EXITED_BUT_INCOMPLETE)
      printf '安装未完成，请联系工作人员处理。\n'
      ;;
    *)
      return 1
      ;;
  esac
}

terminal_heartbeat_message_for_marker() {
  local marker="$1"
  case "$marker" in
    STEP_1_STARTED|STEP_1_DONE)
      printf '仍在准备安装环境，请稍候...\n'
      ;;
    STEP_2_STARTED|STEP_2_DONE)
      printf '仍在检查龙虾环境，请稍候...\n'
      ;;
    STEP_3_STARTED|LIGHT_COMPONENT_DOWNLOAD_STARTED)
      printf '仍在安装灯光连接组件，请稍候...\n'
      ;;
    LIGHT_SERVICE_INSTALL_STARTED|LIGHT_COMPONENT_DOWNLOAD_DONE|MILOCO_INSTALL_STARTED)
      printf '仍在安装灯光服务，请稍候...\n'
      ;;
    STEP_3_DONE|STEP_4_STARTED|STEP_4_DONE|STEP_5_STARTED)
      printf '仍在准备米家连接，请稍候...\n'
      ;;
    XINGUANG_SKILL_PREINSTALL_STARTED|XINGUANG_SKILL_INSTALL_DONE|XINGUANG_SKILL_PREINSTALL_DONE|STEP_5_DONE)
      printf '仍在安装馨光 Skill，请稍候...\n'
      ;;
    STEP_6_STARTED|GATEWAY_RESTART_DONE|GATEWAY_RESTART_SCHEDULED|AGENTCHAT_RECONNECT_EXPECTED)
      printf '仍在验证安装结果，请稍候...\n'
      ;;
    *)
      printf '安装仍在继续，请稍候...\n'
      ;;
  esac
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
    STEP_6_DONE|SUCCESS_ACTIVE|SUCCESS_AFTER_RECONNECT)
      printf '当前进度：\n4/4 安装完成\n\n下一步：\n请发送「绑定米家账号」。\n'
      ;;
    ERROR:*|EXITED_BUT_INCOMPLETE)
      printf '安装暂时无法继续，请联系工作人员处理。\n'
      ;;
    *)
      return 1
      ;;
  esac
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
当前进度：
4/4 安装完成

下一步：
请回到龙虾，发送「绑定米家账号。绑定成功后不要自动选择家庭；如果有多个家庭，请列出家庭让我选择馨光设备所在家庭。」
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
  if state_has STEP_6_DONE || state_has SUCCESS_ACTIVE || state_has SUCCESS_AFTER_RECONNECT; then
    cat <<'EOF'
[100%] 安装完成。

下一步：
请回到龙虾，发送「绑定米家账号」。
EOF
    return
  fi

  if state_has EXITED_BUT_INCOMPLETE || grep -q '^ERROR:' "$STATE_FILE" 2>/dev/null; then
    printf '安装未完成，请联系工作人员处理。\n'
    return
  fi

  local latest message
  latest="$(state_latest_marker)"
  message="$(terminal_progress_message_for_marker "$latest" || true)"
  if [[ -z "$message" ]]; then
    if state_has STEP_5_DONE || state_has XINGUANG_SKILL_PREINSTALL_STARTED || state_has XINGUANG_SKILL_INSTALL_DONE; then
      message='[80%] 正在安装馨光 Skill...'
    elif state_has STEP_3_DONE; then
      message='[75%] 正在准备米家连接...'
    elif state_has STEP_3_STARTED; then
      message='[50%] 正在安装灯光连接组件...'
    elif state_has STEP_2_STARTED; then
      message='[30%] 正在检查龙虾环境...'
    else
      message='[10%] 正在检查系统环境...'
    fi
  fi
  printf '%s\n\n请继续等待，不要重复执行安装命令。\n' "$message"
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
      GATEWAY_RESTART_SCHEDULED|AGENTCHAT_RECONNECT_EXPECTED) key="RECONNECT_EXPECTED" ;;
      STEP_6_DONE|SUCCESS_ACTIVE|SUCCESS_AFTER_RECONNECT) key="INSTALL_COMPLETE" ;;
      ERROR:*|EXITED_BUT_INCOMPLETE) key="INSTALL_INCOMPLETE_OR_ERROR" ;;
    esac
    if ! grep -Fxq "$key" "$seen_file" 2>/dev/null; then
      printf '%s\n' "$message"
      printf '%s\n' "$key" >>"$seen_file"
    fi
  done <"$STATE_FILE"
}

emit_terminal_progress_updates() {
  local seen_file="$1"
  [[ -f "$STATE_FILE" ]] || return 0

  local marker message key
  while IFS= read -r marker; do
    message="$(terminal_progress_message_for_marker "$marker" || true)"
    [[ -n "$message" ]] || continue
    key="$marker"
    case "$marker" in
      STEP_3_STARTED) key="T_PHASE_50" ;;
      LIGHT_COMPONENT_DOWNLOAD_STARTED) key="T_PHASE_60" ;;
      LIGHT_SERVICE_INSTALL_STARTED|LIGHT_COMPONENT_DOWNLOAD_DONE|MILOCO_INSTALL_STARTED) key="T_PHASE_70" ;;
      STEP_4_STARTED|STEP_4_DONE|STEP_5_STARTED) key="T_PHASE_75" ;;
      XINGUANG_SKILL_PREINSTALL_STARTED|XINGUANG_SKILL_INSTALL_DONE|XINGUANG_SKILL_PREINSTALL_DONE|STEP_5_DONE) key="T_PHASE_80" ;;
      STEP_6_STARTED|GATEWAY_RESTART_DONE) key="T_PHASE_90" ;;
      STEP_6_DONE|SUCCESS_ACTIVE|SUCCESS_AFTER_RECONNECT) key="T_INSTALL_COMPLETE" ;;
      ERROR:*|EXITED_BUT_INCOMPLETE) key="T_INSTALL_ERROR" ;;
    esac
    if ! grep -Fxq "$key" "$seen_file" 2>/dev/null; then
      printf '%s\n' "$message"
      printf '%s\n' "$key" >>"$seen_file"
    fi
  done <"$STATE_FILE"
}

state_latest_marker() {
  [[ -f "$STATE_FILE" ]] || {
    printf 'STEP_1_STARTED'
    return
  }
  tail -n 1 "$STATE_FILE" 2>/dev/null || printf 'STEP_1_STARTED'
}

observe_terminal_background_progress() {
  local max_seconds="${FRONT_PROGRESS_MAX_SECONDS:-1800}"
  local interval="${FRONT_PROGRESS_INTERVAL_SECONDS:-5}"
  local heartbeat_seconds="${FRONT_PROGRESS_HEARTBEAT_SECONDS:-20}"
  local elapsed=0
  local heartbeat_elapsed=0
  local seen_file="$WORK_DIR/terminal-progress-seen.txt"
  : >"$seen_file"

  printf '\n开始安装，请稍候。\n\n'

  while (( elapsed <= max_seconds )); do
    emit_terminal_progress_updates "$seen_file"
    if state_has STEP_6_DONE || state_has SUCCESS_ACTIVE || state_has SUCCESS_AFTER_RECONNECT; then
      return 0
    fi
    if state_has EXITED_BUT_INCOMPLETE || grep -q '^ERROR:' "$STATE_FILE" 2>/dev/null; then
      printf '安装未完成，请联系工作人员处理。\n'
      return 0
    fi
    if (( elapsed >= max_seconds )); then
      break
    fi
    sleep "$interval"
    elapsed=$((elapsed + interval))
    heartbeat_elapsed=$((heartbeat_elapsed + interval))
    if (( heartbeat_elapsed >= heartbeat_seconds )); then
      terminal_heartbeat_message_for_marker "$(state_latest_marker)"
      heartbeat_elapsed=0
    fi
  done

  emit_terminal_progress_updates "$seen_file"
  if state_has STEP_6_DONE || state_has SUCCESS_ACTIVE || state_has SUCCESS_AFTER_RECONNECT; then
    return 0
  fi

  if background_supervisor_running; then
    cat <<'EOF'

安装还在继续，请稍候。
如果超过 2 分钟没有新进度，可在当前终端运行：
bash install-xinguang-ai-light.sh status
不要重复执行安装命令。
EOF
  else
    printf '\n安装未完成，请联系工作人员处理。\n'
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
    emit_progress_updates "$seen_file"
    if state_has STEP_6_DONE || state_has SUCCESS_ACTIVE || state_has SUCCESS_AFTER_RECONNECT; then
      return 0
    fi
    if state_has GATEWAY_RESTART_SCHEDULED || state_has AGENTCHAT_RECONNECT_EXPECTED; then
      return 0
    fi
    if (( elapsed >= max_seconds )); then
      break
    fi
    sleep "$interval"
    elapsed=$((elapsed + interval))
  done

  emit_progress_updates "$seen_file"
  if state_has STEP_6_DONE || state_has SUCCESS_ACTIVE || state_has SUCCESS_AFTER_RECONNECT; then
    return 0
  fi

  if background_supervisor_running; then
    cat <<EOF

安装还在继续，请稍候。
如果超过 2 分钟没有新进度，请复制状态查询指令发给龙虾。
不要重复发送一键安装指令。
EOF
  else
    cat <<EOF

安装暂时无法确认。
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

  if have systemd-run && systemd-run --user --unit="$unit" --collect --property=Restart=no /bin/bash "$launcher" >/dev/null 2>&1; then
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
  printf '\n安装暂时无法继续，请联系工作人员处理。\n' >&2
  exit 1
}

on_error() {
  local status=$?
  printf '\n安装暂时无法继续，请联系工作人员处理。\n' >&2
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

  if [[ -n "$nvm_node_dir" && -d "$nvm_node_dir/bin" ]]; then
    export PATH="$nvm_node_dir/bin:$PATH"
  fi
  export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$HOME/.local/share/pnpm:$HOME/.local/share/pnpm/global/5/node_modules/.bin:$PATH"

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

run_openclaw_installer_with_registry() {
  local registry="$1"
  if [[ -n "$registry" ]]; then
    curl -fsSL https://openclaw.ai/install.sh | env \
      OPENCLAW_NO_PROMPT=1 \
      OPENCLAW_NO_ONBOARD=1 \
      OPENCLAW_INSTALL_METHOD=npm \
      npm_config_registry="$registry" \
      bash -s -- --no-onboard --no-prompt --install-method npm
  else
    curl -fsSL https://openclaw.ai/install.sh | env \
      OPENCLAW_NO_PROMPT=1 \
      OPENCLAW_NO_ONBOARD=1 \
      OPENCLAW_INSTALL_METHOD=npm \
      bash -s -- --no-onboard --no-prompt --install-method npm
  fi
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
  local registry
  registry="$(select_npm_registry)"
  if [[ -n "$registry" ]]; then
    log "Using npm registry: $registry"
    if ! run_openclaw_installer_with_registry "$registry"; then
      log "OpenClaw install/update command returned non-zero with npm mirror; checking installed command"
      if accept_openclaw_if_available; then
        log "Continuing because OpenClaw is already usable after installer warning"
        return 0
      fi
      log "Retrying OpenClaw install/update with official npm registry"
      if ! run_openclaw_installer_with_registry ""; then
        accept_openclaw_if_available || return 1
        log "Continuing because OpenClaw is usable after official-registry installer warning"
      fi
    fi
  else
    if ! run_openclaw_installer_with_registry ""; then
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

  if wait_for_openclaw_gateway; then
    gateway_ok=1
  fi

  if [[ "$gateway_ok" != 1 ]] && ss -ltn 2>/dev/null | grep -Eq ":${OPENCLAW_PORT}\\b"; then
    log "龙虾后台服务已就绪，继续后续安装"
    gateway_ok=1
  fi

  if [[ "$gateway_ok" != 1 ]]; then
    log "WARNING: 龙虾后台服务暂未确认就绪，仍会继续安装灯光插件，最终验证会再次检查。"
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
      if wait_for_openclaw_gateway; then
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
    log "正在下载灯光插件组件"
    mapfile -t urls < <(miloco_bundle_urls "$manifest" "$bundle_name" | rank_urls_by_speed "灯光插件组件" 1)
    download_first "$archive" "${urls[@]}" || die "灯光插件组件下载失败"

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

select_npm_registry() {
  if [[ "$NPM_REGISTRY" != auto ]]; then
    printf '%s' "$NPM_REGISTRY"
    return
  fi

  if [[ "$AUTO_SELECT_MIRRORS" != 1 ]]; then
    printf '%s' 'https://registry.npmmirror.com'
    return
  fi

  local registry test_url result_file failed_file elapsed
  result_file="$WORK_DIR/npm.speed"
  failed_file="$WORK_DIR/npm.failed"
  : >"$result_file"
  : >"$failed_file"

  log "Benchmarking npm registries"
  while IFS= read -r registry; do
    [[ -n "$registry" ]] || continue
    test_url="${registry%/}/openclaw"
    if elapsed="$(benchmark_url "$test_url" 0)"; then
      log "  ${elapsed}s  $registry"
      printf '%s\t%s\n' "$elapsed" "$registry" >>"$result_file"
    else
      log "  failed  $registry"
      printf '%s\n' "$registry" >>"$failed_file"
    fi
  done < <(available_npm_registries)

  if [[ -s "$result_file" ]]; then
    sort -n "$result_file" | head -1 | cut -f2-
  else
    printf '%s' 'https://registry.npmjs.org'
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
  wait_for_openclaw_gateway || {
    repair_gateway_deactivating_if_needed || true
    wait_for_openclaw_gateway || true
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

  if [[ -n "$MIMO_API_KEY" ]]; then
    log "Configuring MiMo API key"
    miloco-cli config set model.omni.api_key "$MIMO_API_KEY" --no-restart
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
  else
    printf '龙虾环境: 未确认\n'
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
  [[ -f "$HOME/wainfort-light/target-home.env" ]] && return 0
  [[ -f /tmp/xinguang-skill-install.state ]] &&
    grep -Eq 'HOME_SELECTION_SINGLE_HOME_AUTO|HOME_SWITCH_DONE|DEVICE_LIST_READY|XINGUANG_SKILL_INSTALL_DONE' /tmp/xinguang-skill-install.state
}

xinguang_skill_installed_known() {
  state_has XINGUANG_SKILL_INSTALL_DONE && return 0
  [[ -f /tmp/xinguang-skill-install.state ]] &&
    grep -Eq 'XINGUANG_SKILL_INSTALL_DONE|LIGHT_TEST_SUCCESS|PHYSICAL_SUCCESS_API_FALSE' /tmp/xinguang-skill-install.state
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

灯光能力暂未安装完成，请联系工作人员处理。
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

preinstall_xinguang_skill() {
  local install_dir="$XINGUANG_LOCAL_INSTALL_DIR"
  local bin_dir="$HOME/.local/bin"
  local entry="$install_dir/install-xinguang-ai-skill.sh"
  local main="$install_dir/install-xinguang-skill.sh"
  local shortcut="$install_dir/xinguang-install-skill"
  local path_shortcut="$bin_dir/xinguang-install-skill"

  mkdir -p "$install_dir" "$bin_dir"

  download_versioned_file "$entry" "ENTRY_VERSION=\"$XINGUANG_SKILL_ENTRY_VERSION\"" \
    "https://nijez.github.io/xingguang-ai-lighting-guide/staging/2026-06-25.20/install-xinguang-ai-skill.sh" \
    "https://raw.githubusercontent.com/nijez/xingguang-ai-lighting-guide/main/install-xinguang-ai-skill.sh" \
    "https://cdn.jsdelivr.net/gh/nijez/xingguang-ai-lighting-guide@main/install-xinguang-ai-skill.sh" ||
    die

  download_versioned_file "$main" "XINGUANG_SKILL_INSTALLER_VERSION=\"$XINGUANG_SKILL_INSTALLER_VERSION\"" \
    "https://nijez.github.io/xingguang-ai-lighting-guide/staging/2026-06-25.20/install-xinguang-skill.sh" \
    "https://raw.githubusercontent.com/nijez/xingguang-ai-lighting-guide/main/install-xinguang-skill.sh" \
    "https://cdn.jsdelivr.net/gh/nijez/xingguang-ai-lighting-guide@main/install-xinguang-skill.sh" ||
    die

  cat >"$shortcut" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
TARGET="$main" INSTALL_ACTION=continue INSTALL_NONINTERACTIVE=1 bash "$entry"
EOF
  chmod +x "$shortcut"
  cp "$shortcut" "$path_shortcut" 2>/dev/null || true

  state_mark XINGUANG_SKILL_PREINSTALL_STARTED
  TARGET="$main" INSTALL_ACTION=preinstall INSTALL_NONINTERACTIVE=1 bash "$entry" preinstall ||
    die "馨光 Skill 安装失败"
  state_mark XINGUANG_SKILL_INSTALL_DONE
  state_mark XINGUANG_SKILL_PREINSTALL_DONE

  cat >"$install_dir/灯光测试提示.txt" <<'EOF'
米家账号绑定并选择家庭后，可以直接测试灯光：
客厅来个马尔代夫的海边日落
EOF
}

run_full_deploy() {
  local step_start
  TOTAL_STEPS=6
  state_init
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
    print_step_note "安装馨光 Skill，并提示后续绑定米家账号。"
    preinstall_xinguang_skill
    prompt_mihome_binding
    step_done_msg 5 "米家账号绑定提示" "$step_start"
    log_timing_since "米家账号绑定提示" "$step_start"
  fi

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

  if state_has STEP_6_DONE || state_has SUCCESS_ACTIVE || state_has SUCCESS_AFTER_RECONNECT; then
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
