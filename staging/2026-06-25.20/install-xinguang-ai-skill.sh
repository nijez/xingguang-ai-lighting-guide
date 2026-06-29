#!/usr/bin/env bash
set -Eeuo pipefail

ENTRY_VERSION="2026-06-26.9"
INSTALLER_VERSION="2026-06-26.9"
TARGET="${TARGET:-/tmp/xinguang-skill-install.sh}"
ACTION="${1:-${INSTALL_ACTION:-install}}"

download_installer() {
  local tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/xinguang-skill-installer.XXXXXX")"
  rm -f "$TARGET"

  local url
  for url in \
    "https://nijez.github.io/xingguang-ai-lighting-guide/staging/2026-06-25.20/install-xinguang-skill.sh" \
    "https://raw.githubusercontent.com/nijez/xingguang-ai-lighting-guide/main/install-xinguang-skill.sh" \
    "https://cdn.jsdelivr.net/gh/nijez/xingguang-ai-lighting-guide@main/install-xinguang-skill.sh"
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
