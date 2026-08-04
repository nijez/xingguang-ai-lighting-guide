#!/usr/bin/env bash
set -Eeuo pipefail

ENTRY_VERSION="2026-06-26.18"
INSTALLER_VERSION="2026-06-26.18"
TARGET="${TARGET:-/tmp/xinguang-skill-install.sh}"
ACTION="${1:-${INSTALL_ACTION:-install}}"

download_installer() {
  local tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/xinguang-skill-installer.XXXXXX")"
  rm -f "$TARGET"

  local url
  for url in \
    "https://nijez.github.io/xingguang-ai-lighting-guide/install-xinguang-skill.sh" \
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
  if [[ ! -f "$TARGET" ]] ||
    ! grep -q "XINGUANG_SKILL_INSTALLER_VERSION=\"$INSTALLER_VERSION\"" "$TARGET" 2>/dev/null; then
    local state_file="${STATE_FILE:-/tmp/xinguang-skill-install.state}"
    local target_home_file="${TARGET_HOME_FILE:-${XINGUANG_BASE_DIR:-$HOME/xinguang-ai-light}/target-home.env}"
    local skill_file="$HOME/.openclaw/skills/wainfort-ai-lighting-run/SKILL.md"
    local installed_version="" family_name="未设置" systemd_state="未检测到 systemd" systemd_raw conclusion
    local state_done=0 state_needs_home=0

    if command -v python3 >/dev/null 2>&1; then
      local status_values
      status_values="$(python3 - "$skill_file" "$target_home_file" <<'PY' 2>/dev/null || true
import json
import shlex
import sys

skill_path, home_path = sys.argv[1:]
version = ""
family = ""

try:
    lines = open(skill_path, encoding="utf-8").read().splitlines()
    if lines and lines[0] == "---":
        for line in lines[1:]:
            if line == "---":
                break
            if line.startswith("metadata:"):
                metadata = json.loads(line.split(":", 1)[1].strip())
                value = metadata.get("openclaw", {}).get("version", "")
                if isinstance(value, str):
                    version = value
                break
except (OSError, ValueError, AttributeError, json.JSONDecodeError):
    pass

try:
    with open(home_path, encoding="utf-8") as config_file:
        for line in config_file:
            if line.startswith("XINGUANG_TARGET_HOME="):
                parsed = shlex.split(line.split("=", 1)[1].strip(), posix=True)
                if len(parsed) == 1:
                    family = parsed[0]
                break
except (OSError, ValueError):
    pass

print(f"{version}\x1f{family}")
PY
)"
      IFS=$'\x1f' read -r installed_version family_name <<<"$status_values"
    elif [[ -f "$target_home_file" ]]; then
      family_name="$(sed -n 's/^XINGUANG_TARGET_HOME=//p' "$target_home_file" | head -n 1)"
    fi
    if [[ -f "$target_home_file" && -z "$family_name" ]]; then
      family_name="已设置（家庭名未读取到）"
    fi

    if command -v systemctl >/dev/null 2>&1; then
      systemd_raw="$(systemctl is-active xinguang-wainfort.service 2>/dev/null || true)"
      case "$systemd_raw" in
        active) systemd_state="运行中" ;;
        inactive) systemd_state="未运行" ;;
        failed) systemd_state="启动失败" ;;
        activating) systemd_state="启动中" ;;
        deactivating) systemd_state="停止中" ;;
        *) systemd_state="未安装或无法读取" ;;
      esac
    fi
    if [[ -f "$state_file" ]] && grep -q XINGUANG_SKILL_INSTALL_DONE "$state_file"; then
      state_done=1
    fi
    if [[ -f "$state_file" ]] && grep -q HOME_SELECTION_REQUIRED "$state_file"; then
      state_needs_home=1
    fi

    printf '馨光 Skill 安装状态（只读）：\n'
    printf '最近状态：\n'
    if [[ -s "$state_file" ]]; then
      tail -n 5 "$state_file" 2>/dev/null || printf '状态记录读取失败。\n'
    else
      printf '暂无状态记录。\n'
    fi
    if [[ -n "$installed_version" ]]; then
      printf '已装 Skill 版本：%s\n' "$installed_version"
    else
      printf '已装 Skill 版本：未检测到\n'
    fi
    printf '家庭配置：%s\n' "$family_name"
    printf '灯光服务 systemd 状态：%s\n' "$systemd_state"

    if (( state_done == 1 )) || { [[ -n "$installed_version" ]] && [[ "$systemd_state" == "运行中" ]]; }; then
      conclusion="已完成"
    elif [[ ! -f "$target_home_file" ]] && (( state_needs_home == 1 )); then
      conclusion="需要选择家庭"
    elif [[ -f "$state_file" ]] || [[ -n "$installed_version" ]] || [[ "$systemd_state" == "运行中" ]]; then
      conclusion="进行中"
    else
      conclusion="未开始"
    fi

    printf '\n安装状态：%s\n' "$conclusion"
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
