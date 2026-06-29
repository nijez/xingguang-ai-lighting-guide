#!/usr/bin/env bash
set -Eeuo pipefail

XINGUANG_PANEL_SH_VERSION="2026-06-29.2"
BASE_DIR="${XINGUANG_BASE_DIR:-$HOME/xinguang-ai-light}"

if command -v xinguang-panel >/dev/null 2>&1; then
  exec xinguang-panel "$@"
fi

if [[ -x "$BASE_DIR/xinguang-panel" ]]; then
  exec "$BASE_DIR/xinguang-panel" "$@"
fi

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$DIR/xinguang-panel" "$@"
