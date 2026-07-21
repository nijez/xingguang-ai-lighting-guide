#!/usr/bin/env bash
set -Eeuo pipefail

ENTRY_VERSION="2026-06-25.48"
INSTALLER_VERSION="2026-06-25.48"
BASE_DIR="${XINGUANG_BASE_DIR:-$HOME/xinguang-ai-light}"
TARGET="${TARGET:-$BASE_DIR/install-cache/install-miloco-openclaw-cloud.sh}"
STATE_FILE="${STATE_FILE:-$BASE_DIR/state/xinguang-light-install.state}"
LOG_FILE="${LOG_FILE:-$BASE_DIR/logs/xinguang-light-install-current.log}"
RUN_MARKER="${RUN_MARKER:-$BASE_DIR/state/xinguang-light-install.marker}"
ACTION="${1:-install}"

mkdir -p "$BASE_DIR/install-cache" "$BASE_DIR/state" "$BASE_DIR/logs"

is_dragon_parent_process() {
  local pid="${PPID:-}" depth=0 line next
  while [[ -n "$pid" && "$pid" =~ ^[0-9]+$ && "$pid" -gt 1 && "$depth" -lt 16 ]]; do
    line="$(ps -p "$pid" -o comm= -o args= 2>/dev/null || true)"
    if printf '%s\n' "$line" | grep -Eiq 'openclaw|agentchat|clawbot|lightclaw|miloco'; then
      return 0
    fi
    next="$(ps -p "$pid" -o ppid= 2>/dev/null | tr -d '[:space:]' || true)"
    [[ -n "$next" && "$next" != "$pid" ]] || break
    pid="$next"
    depth=$((depth + 1))
  done
  return 1
}

require_terminal_context() {
  [[ "${XINGUANG_ALLOW_NON_TTY:-0}" == "1" ]] && return 0
  if [[ ! -t 0 || ! -t 1 ]] || is_dragon_parent_process; then
    cat <<'EOF'
请在腾讯云免密终端里手动运行这条命令。
不要把这条命令发到龙虾对话窗口。
EOF
    exit 2
  fi
}

require_terminal_context

download_installer() {
  local tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/xinguang-light-installer.XXXXXX")"
  rm -f "$TARGET"

  local url
  for url in \
    "https://raw.githubusercontent.com/nijez/xingguang-ai-lighting-guide/main/closed-beta/2026-06-29/install-miloco-openclaw-cloud.sh"
  do
    if curl -fsSL "$url" -o "$tmp" &&
      grep -q "SCRIPT_VERSION=\"$INSTALLER_VERSION\"" "$tmp"; then
      mv "$tmp" "$TARGET"
      chmod +x "$TARGET"
      return 0
    fi
  done

  rm -f "$tmp"
  return 1
}

ensure_installer() {
  if [[ -f "$TARGET" ]] &&
    grep -q "SCRIPT_VERSION=\"$INSTALLER_VERSION\"" "$TARGET" 2>/dev/null; then
    chmod +x "$TARGET"
    return 0
  fi
  download_installer
}

run_status() {
  if ! ensure_installer; then
    printf '暂时无法读取安装进度，请联系工作人员处理。\n'
    return 0
  fi

  RUN_CONTEXT=terminal_status \
    INSTALL_ACTION=status \
    INSTALL_NONINTERACTIVE=1 \
    STATE_FILE="$STATE_FILE" \
    LOG_FILE="$LOG_FILE" \
    PID_FILE="$RUN_MARKER" \
    bash "$TARGET"
}

run_install() {
  if ! ensure_installer; then
    printf '安装脚本下载失败，请联系工作人员处理。\n'
    return 1
  fi

  RUN_CONTEXT=terminal_installer \
    DEPLOY_SUPERVISOR=1 \
    INSTALL_ACTION=full \
    RUN_SYSTEM_UPGRADE=0 \
    OPENCLAW_UPDATE=auto \
    INSTALL_EXTRA_PLUGINS=0 \
    INSTALL_NONINTERACTIVE=1 \
    FRONT_PROGRESS_MAX_SECONDS="${FRONT_PROGRESS_MAX_SECONDS:-1800}" \
    FRONT_PROGRESS_INTERVAL_SECONDS="${FRONT_PROGRESS_INTERVAL_SECONDS:-5}" \
    STATE_FILE="$STATE_FILE" \
    LOG_FILE="$LOG_FILE" \
    PID_FILE="$RUN_MARKER" \
    bash "$TARGET"
}

case "$ACTION" in
  status|progress)
    run_status
    ;;
  *)
    run_install
    ;;
esac
