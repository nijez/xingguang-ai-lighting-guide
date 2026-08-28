#!/usr/bin/env bash
set -Eeuo pipefail

ENTRY_VERSION="2026-06-25.55"
INSTALLER_VERSION="2026-06-25.55"
TARGET="${TARGET:-/tmp/xinguang-light-install.sh}"
STATE_FILE="${STATE_FILE:-/tmp/xinguang-light-install.state}"
LOG_FILE="${LOG_FILE:-/tmp/xinguang-light-install-current.log}"
RUN_MARKER="${RUN_MARKER:-/tmp/xinguang-light-install.marker}"
ACTION="${1:-install}"

absolute_path() {
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    *) printf '%s/%s\n' "$PWD" "$1" ;;
  esac
}

STATE_FILE="$(absolute_path "$STATE_FILE")"

download_installer() {
  local tmp url downloaded=0
  tmp="$(mktemp "${TMPDIR:-/tmp}/xinguang-light-installer.XXXXXX")"
  for url in \
    "https://nijez.github.io/xingguang-ai-lighting-guide/install-miloco-openclaw-cloud.sh" \
    "https://raw.githubusercontent.com/nijez/xingguang-ai-lighting-guide/main/install-miloco-openclaw-cloud.sh" \
    "https://cdn.jsdelivr.net/gh/nijez/xingguang-ai-lighting-guide@main/install-miloco-openclaw-cloud.sh" \
    "https://gh-proxy.com/raw.githubusercontent.com/nijez/xingguang-ai-lighting-guide/main/install-miloco-openclaw-cloud.sh" \
    "https://ghproxy.net/https://raw.githubusercontent.com/nijez/xingguang-ai-lighting-guide/main/install-miloco-openclaw-cloud.sh"
  do
    if curl -fsSL --max-time 60 --retry 2 --retry-delay 2 "$url" -o "$tmp"; then
      downloaded=1
      if grep -q "SCRIPT_VERSION=\"$INSTALLER_VERSION\"" "$tmp"; then
        mv "$tmp" "$TARGET"
        chmod +x "$TARGET"
        return 0
      fi
    fi
  done

  rm -f "$tmp"
  if (( downloaded )); then
    return 2
  fi
  return 1
}

ensure_installer() {
  if [[ -f "$TARGET" ]] &&
    grep -q "SCRIPT_VERSION=\"$INSTALLER_VERSION\"" "$TARGET" 2>/dev/null; then
    chmod +x "$TARGET"
    return 0
  fi

  local download_status=0
  download_installer || download_status=$?
  if [[ "$download_status" == 2 ]] && [[ -f "$TARGET" ]]; then
    chmod +x "$TARGET"
    printf '线上版本缓存未刷新，已使用当前已安装版本\n'
    return 0
  fi
  if [[ "$download_status" == 1 ]] && [[ -f "$TARGET" ]]; then
    chmod +x "$TARGET"
    printf '网络暂不可用，已使用本地已安装版本继续。\n'
    return 0
  fi

  return "$download_status"
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
