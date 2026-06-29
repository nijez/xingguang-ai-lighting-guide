#!/usr/bin/env bash
set -Eeuo pipefail

ENTRY_VERSION="2026-06-25.20"
INSTALLER_VERSION="2026-06-25.20"
TARGET="${TARGET:-/tmp/xinguang-light-install.sh}"
STATE_FILE="${STATE_FILE:-/tmp/xinguang-light-install.state}"
LOG_FILE="${LOG_FILE:-/tmp/xinguang-light-install-current.log}"
RUN_MARKER="${RUN_MARKER:-/tmp/xinguang-light-install.marker}"
ACTION="${1:-install}"

download_installer() {
  local tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/xinguang-light-installer.XXXXXX")"
  rm -f "$TARGET"

  local url
  for url in \
    "https://nijez.github.io/xingguang-ai-lighting-guide/staging/2026-06-25.20/install-miloco-openclaw-cloud.sh" \
    "https://raw.githubusercontent.com/nijez/xingguang-ai-lighting-guide/main/install-miloco-openclaw-cloud.sh" \
    "https://cdn.jsdelivr.net/gh/nijez/xingguang-ai-lighting-guide@main/install-miloco-openclaw-cloud.sh"
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
