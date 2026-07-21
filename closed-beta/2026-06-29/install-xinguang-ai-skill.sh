#!/usr/bin/env bash
set -Eeuo pipefail

ENTRY_VERSION="2026-06-26.20"
INSTALLER_VERSION="2026-06-26.20"
BASE_DIR="${XINGUANG_BASE_DIR:-$HOME/xinguang-ai-light}"
TARGET="${TARGET:-$BASE_DIR/install-cache/install-xinguang-skill.sh}"
ACTION="${1:-${INSTALL_ACTION:-install}}"

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
  tmp="$(mktemp "${TMPDIR:-/tmp}/xinguang-skill-installer.XXXXXX")"
  rm -f "$TARGET"

  local url
  for url in \
    "https://raw.githubusercontent.com/nijez/xingguang-ai-lighting-guide/main/closed-beta/2026-06-29/install-xinguang-skill.sh"
  do
    if curl -fsSL "$url" -o "$tmp" &&
      grep -q "XINGUANG_SKILL_INSTALLER_VERSION=\"$INSTALLER_VERSION\"" "$tmp"; then
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
    grep -q "XINGUANG_SKILL_INSTALLER_VERSION=\"$INSTALLER_VERSION\"" "$TARGET" 2>/dev/null; then
    chmod +x "$TARGET"
    return 0
  fi
  download_installer
}

run_status() {
  if ! ensure_installer; then
    printf '暂时无法读取馨光 Skill 安装进度，请联系工作人员处理。\n'
    return 0
  fi

  INSTALL_ACTION=status INSTALL_NONINTERACTIVE=1 bash "$TARGET"
}

run_install() {
  if ! ensure_installer; then
    printf '馨光 Skill 安装脚本下载失败，请联系工作人员处理。\n'
    return 1
  fi

  INSTALL_ACTION=continue INSTALL_NONINTERACTIVE=1 bash "$TARGET"
}

run_preinstall() {
  if ! ensure_installer; then
    printf '馨光 Skill 安装脚本下载失败，请联系工作人员处理。\n'
    return 1
  fi

  INSTALL_ACTION=preinstall INSTALL_NONINTERACTIVE=1 bash "$TARGET"
}

case "$ACTION" in
  status|progress)
    run_status
    ;;
  preinstall)
    run_preinstall
    ;;
  *)
    run_install
    ;;
esac
