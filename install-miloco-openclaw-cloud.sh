#!/usr/bin/env bash
set -Eeuo pipefail

# One-shot OpenClaw + Xiaomi Miloco installer for a Tencent Cloud OpenClaw app-template VM.
# Defaults are intentionally conservative:
# - OpenClaw gateway binds to loopback only.
# - Mi Home account binding is skipped.
# - WeChat channel installation/login is skipped.
# - MiMo API key is configured only when MIMO_API_KEY is supplied.

SCRIPT_VERSION="2026-06-24.2"
TOTAL_STEPS=6
MILOCO_VERSION="${MILOCO_VERSION:-2026.6.18}"
OPENCLAW_PORT="${OPENCLAW_PORT:-18789}"
OPENCLAW_BIND="${OPENCLAW_BIND:-loopback}"
OPENCLAW_MIN_VERSION="${OPENCLAW_MIN_VERSION:-2026.6.10}"
RUN_SYSTEM_UPGRADE="${RUN_SYSTEM_UPGRADE:-0}"
OPENCLAW_UPDATE="${OPENCLAW_UPDATE:-0}"
INSTALL_EXTRA_PLUGINS="${INSTALL_EXTRA_PLUGINS:-0}"
INSTALL_ACTION="${INSTALL_ACTION:-}"
INSTALL_NONINTERACTIVE="${INSTALL_NONINTERACTIVE:-0}"
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
  printf 'INSTALL_ACTION=continue RUN_SYSTEM_UPGRADE=0 OPENCLAW_UPDATE=0 INSTALL_EXTRA_PLUGINS=0 INSTALL_NONINTERACTIVE=1 bash /tmp/install-miloco-openclaw-cloud.sh'
}

print_incomplete_report() {
  local reason="${1:-unknown}"
  if state_has STEP_6_DONE; then
    return 0
  fi
  cat >&2 <<EOF

部署未完成 / 可恢复中断
最后完成步骤: $(state_last_done)
中断位置: $(state_next_step)
疑似原因: $reason
是否可以继续: 是
建议执行: $(recommended_continue_command)
状态文件: $STATE_FILE
日志文件: $LOG_FILE
EOF
}

step_start_msg() {
  local number="$1"
  local title="$2"
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

die() {
  printf '\nERROR: %s\n' "$*" >&2
  printf 'Log file: %s\n' "$LOG_FILE" >&2
  exit 1
}

on_error() {
  local status=$?
  printf '\nERROR: Script failed near line %s with exit code %s\n' "${BASH_LINENO[0]:-unknown}" "$status" >&2
  printf 'Log file: %s\n' "$LOG_FILE" >&2
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

  if timeout 60s openclaw gateway restart; then
    log "OpenClaw gateway restart requested"
  else
    log "OpenClaw gateway restart returned non-zero; checking status"
  fi

  if wait_for_openclaw_gateway; then
    gateway_ok=1
  fi

  if [[ "$gateway_ok" != 1 ]] && ss -ltn 2>/dev/null | grep -Eq ":${OPENCLAW_PORT}\\b"; then
    log "OpenClaw gateway port $OPENCLAW_PORT is listening; continuing despite status probe warning"
    gateway_ok=1
  fi

  if [[ "$gateway_ok" != 1 ]]; then
    log "WARNING: OpenClaw gateway is not confirmed ready yet. Miloco install will continue; final verification will report gateway status."
  fi

  report_openclaw_versions || true

  return 0
}

install_openclaw() {
  setup_runtime_paths

  if ! have openclaw; then
    log "Installing OpenClaw"
    run_openclaw_installer
    setup_runtime_paths
  else
    local current_version
    current_version="$(openclaw_version_number || true)"
    log "OpenClaw already installed: $(openclaw --version 2>/dev/null || true)"
    if [[ "$OPENCLAW_UPDATE" == 1 ]]; then
      log "Updating OpenClaw"
      run_openclaw_installer
      setup_runtime_paths
    else
      if [[ -n "$current_version" ]] && ! version_ge "$current_version" "$OPENCLAW_MIN_VERSION"; then
        log "OpenClaw CLI version $current_version is below required $OPENCLAW_MIN_VERSION; updating despite OPENCLAW_UPDATE=0"
        run_openclaw_installer
        setup_runtime_paths
      else
        log "Skipping OpenClaw package update (OPENCLAW_UPDATE=0 and installed version satisfies $OPENCLAW_MIN_VERSION)"
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
  [[ -n "$bundle_name" && "$bundle_name" != "null" ]] || die "No Miloco bundle for $key"

  cache_dir="$MILOCO_HOME/.install-cache/$version"
  if compgen -G "$cache_dir/miloco-*.whl" >/dev/null &&
    compgen -G "$cache_dir/miloco-models-*.tar.gz" >/dev/null &&
    compgen -G "$cache_dir/*.tgz" >/dev/null; then
    log "Miloco bundle cache already present: $cache_dir"
    return
  fi

  archive="$WORK_DIR/$bundle_name"
  persistent_dir="$MILOCO_CLOUD_CACHE/$version"
  persistent_archive="$persistent_dir/$bundle_name"

  if [[ "$CACHE_MILOCO_BUNDLE" == 1 && -f "$persistent_archive" ]]; then
    local cached_sha
    cached_sha="$(sha256_file "$persistent_archive")"
    if [[ "$cached_sha" == "$bundle_sha" ]]; then
      log "Using cached Miloco bundle archive: $persistent_archive"
      archive="$persistent_archive"
    else
      log "Cached Miloco bundle SHA mismatch, redownloading"
      rm -f "$persistent_archive"
    fi
  fi

  if [[ "$archive" != "$persistent_archive" ]]; then
    log "Preloading Miloco bundle $bundle_name (${bundle_size} bytes)"
    mapfile -t urls < <(miloco_bundle_urls "$manifest" "$bundle_name" | rank_urls_by_speed "Miloco bundle" 1)
    download_first "$archive" "${urls[@]}" || die "Failed to download Miloco bundle"

    local actual_sha
    actual_sha="$(sha256_file "$archive")"
    [[ "$actual_sha" == "$bundle_sha" ]] || die "Miloco bundle SHA mismatch: $actual_sha != $bundle_sha"

    if [[ "$CACHE_MILOCO_BUNDLE" == 1 ]]; then
      mkdir -p "$persistent_dir"
      cp -f "$archive" "$persistent_archive"
      log "Cached Miloco bundle archive: $persistent_archive"
    fi
  fi

  rm -rf "$MILOCO_HOME/.install-cache"
  mkdir -p "$cache_dir"
  tar -xzf "$archive" -C "$cache_dir"

  compgen -G "$cache_dir/miloco-*.whl" >/dev/null || die "Bundle missing miloco wheel"
  compgen -G "$cache_dir/miloco-models-*.tar.gz" >/dev/null || die "Bundle missing model archive"
  compgen -G "$cache_dir/*.tgz" >/dev/null || die "Bundle missing OpenClaw plugin package"
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
    log "No offline wheelhouse URL supplied; using Miloco bundle and PyPI/npm mirrors"
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

  log "Benchmarking PyPI indexes"
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

  log "Running Miloco $phase with PyPI index: $index_url"
  if UV_DEFAULT_INDEX="$index_url" PIP_INDEX_URL="$index_url" bash "$installer" "$phase" </dev/null; then
    return 0
  fi

  if [[ "$PYPI_FALLBACK_OFFICIAL" == 1 && "$index_url" != "https://pypi.org/simple" ]]; then
    log "Miloco $phase failed with mirror index; retrying official PyPI"
    UV_DEFAULT_INDEX="https://pypi.org/simple" PIP_INDEX_URL="https://pypi.org/simple" bash "$installer" "$phase" </dev/null
    return $?
  fi

  return 1
}

wait_for_miloco_service() {
  log "Waiting for Miloco service"
  local status_file="$WORK_DIR/miloco-service-status.json"
  local attempt
  for attempt in {1..30}; do
    if miloco-cli service status >"$status_file" 2>/dev/null &&
      jq -e '.running == true' "$status_file" >/dev/null 2>&1; then
      log "Miloco service is running"
      cat "$status_file"
      return 0
    fi
    sleep 2
  done

  log "Miloco service did not report running yet"
  cat "$status_file" 2>/dev/null || true
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

install_miloco() {
  local installer="$WORK_DIR/install-miloco.sh"
  mapfile -t urls < <(miloco_installer_urls | rank_urls_by_speed "Miloco installer" 1)

  log "Downloading Miloco installer"
  download_first "$installer" "${urls[@]}" || die "Failed to download Miloco installer"
  chmod +x "$installer"

  if [[ "$PRELOAD_MILOCO_BUNDLE" == 1 ]]; then
    preload_miloco_bundle "$installer"
  fi

  setup_wheelhouse_if_requested

  setup_runtime_paths

  # Redirect stdin so Miloco installer skips Mi Home and model prompts.
  run_miloco_phase "$installer" --agent-prepare

  run_miloco_phase "$installer" --agent-finish

  if [[ -n "$MIMO_API_KEY" ]]; then
    log "Configuring MiMo API key"
    miloco-cli config set model.omni.api_key "$MIMO_API_KEY" --no-restart
  fi

  miloco-cli service start >/dev/null 2>&1 || true
  openclaw gateway restart || log "WARNING: OpenClaw gateway restart failed after Miloco install; final verification will report status"
  wait_for_miloco_service || true
  wait_for_openclaw_gateway || true
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
  log "Verification"
  setup_runtime_paths
  printf 'Script version: %s\n' "$SCRIPT_VERSION"
  if have openclaw; then
    printf 'OpenClaw CLI version: %s\n' "$(openclaw_version_number || printf unknown)"
    printf 'OpenClaw Gateway version: %s\n' "$(openclaw_gateway_version_number || printf unknown)"
  fi
  miloco-cli service status || true
  timeout 20s openclaw gateway status | sed -n '1,45p' || true
  openclaw plugins list | grep -i -C 2 'miloco\|weixin' || true
  if [[ -f /var/run/reboot-required ]]; then
    log "Reboot recommended: the system installed a new kernel. Run 'sudo reboot' after this deployment if you want the new kernel active."
  fi
  df -h /
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
      printf '  ✓ Miloco service: running 127.0.0.1:1810\n'
    else
      printf '  - Miloco service: installed, not running\n'
    fi
  else
    printf '  - Miloco service: not installed\n'
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
     依赖检查 -> OpenClaw 状态检查 -> Miloco 2.0 -> 平台/米家绑定提示

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

  2) Miloco 2.0 安装 / 更新
     只安装或更新 Miloco、插件和 allowlist

  3) 核心模块更新 / 修复
     从状态文件继续，跳过系统大升级和 OpenClaw 主动升级

  4) 重启 OpenClaw gateway

  5) 重启 Miloco service

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
  have miloco-cli || die "Miloco is not installed yet. Run one-click deploy or Miloco maintenance first."
  log "Restarting Miloco service"
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
  local action_label="$1"
  cat <<EOF

Xingguang AI lighting installer
Script version: $SCRIPT_VERSION
Action: $action_label
Mode:
  - Ubuntu upgrade: $RUN_SYSTEM_UPGRADE
  - OpenClaw update: $OPENCLAW_UPDATE
  - Extra OpenClaw plugins: $INSTALL_EXTRA_PLUGINS
  - Non-interactive prompts: $INSTALL_NONINTERACTIVE
  - OpenClaw bind: $OPENCLAW_BIND:$OPENCLAW_PORT
  - Miloco version: $MILOCO_VERSION
  - WeChat plugin/login: $INSTALL_WEIXIN_PLUGIN
  - Mi Home account: skipped by default
  - MiMo API key: $([[ -n "$MIMO_API_KEY" ]] && printf configured || printf not-configured)
Log file: $LOG_FILE
State file: $STATE_FILE
EOF
}

print_next_actions() {
  cat <<EOF

Next manual steps:
  1. Configure model key if not supplied:
     miloco-cli config set model.omni.api_key sk-xxx
  2. Bind Mi Home account when ready:
     miloco-cli account bind
  3. Confirm Xingguang light devices are visible:
     miloco-cli device list
  4. Bind personal WeChat later:
     INSTALL_ACTION=weixin RUN_SYSTEM_UPGRADE=0 bash /tmp/install-miloco-openclaw-cloud.sh
  5. Install the Xingguang intelligent Skill later in phase 2.
  6. The Miloco dashboard listens on the cloud server loopback only.
     If you need to open it from your computer, keep an SSH tunnel running:
     ssh -L 1810:127.0.0.1:1810 <user>@<server>
     then visit http://127.0.0.1:1810/ on your computer.
EOF
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
    log "Miloco CLI not found; skipping Mi Home binding prompt"
    return 0
  fi

  if [[ "$INSTALL_NONINTERACTIVE" == 1 || ! -t 0 ]]; then
    cat <<'EOF'

Miloco 米家账号绑定需要打开授权链接或页面，本次无人值守部署自动跳过。
后续在服务器上执行:
  miloco-cli account bind
EOF
    return 0
  fi

  if ask_yes_no "是否现在生成 Miloco 米家账号绑定链接？" n; then
    miloco-cli account bind || true
  else
    cat <<'EOF'
已跳过米家账号绑定。
后续在服务器上执行:
  miloco-cli account bind
EOF
  fi
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
    step_skip_msg 3 "Install and deploy Miloco 2.0" "state already has STEP_3_DONE"
  else
    step_start="$(date +%s)"
    step_start_msg 3 "Install and deploy Miloco 2.0"
    print_step_note "下载 Miloco 2.0、安装服务和项目必要插件；不默认安装 discord、slack、qqbot、whatsapp 等额外插件。"
    install_miloco
    step_done_msg 3 "Install and deploy Miloco 2.0" "$step_start"
    log_timing_since "Miloco" "$step_start"
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
    step_skip_msg 5 "Prompt Miloco Mi Home account binding" "state already has STEP_5_DONE"
  else
    step_start="$(date +%s)"
    step_start_msg 5 "Prompt Miloco Mi Home account binding"
    print_step_note "默认跳过米家账号绑定和 MiMo Key 写入；后续由人工在安全环境配置。"
    prompt_mihome_binding
    step_done_msg 5 "Prompt Miloco Mi Home account binding" "$step_start"
    log_timing_since "Miloco Mi Home binding prompt" "$step_start"
  fi

  if state_has STEP_6_DONE; then
    step_skip_msg 6 "Verify services and print next manual actions" "state already has STEP_6_DONE"
  else
    step_start="$(date +%s)"
    step_start_msg 6 "Verify services and print next manual actions"
    print_step_note "检查 Miloco 服务、OpenClaw 网关、插件状态和端口监听。"
    verify_install
    log "Done"
    log_timing_since "Total install" "$SCRIPT_START_EPOCH"
    step_done_msg 6 "Verify services and print next manual actions" "$step_start"
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
  step_start_msg 3 "Verify services and ports"
  verify_install
  step_done_msg 3 "Verify services and ports" "$step_start"
  log_timing_since "OpenClaw action" "$action_start"
  OPENCLAW_UPDATE="$previous_update"
}

run_miloco_deploy() {
  local step_start action_start previous_update
  TOTAL_STEPS=4
  action_start="$(date +%s)"
  print_mode_summary "miloco"

  step_start="$(date +%s)"
  step_start_msg 1 "Base packages check"
  with_system_upgrade_disabled apt_bootstrap
  step_done_msg 1 "Base packages check" "$step_start"

  step_start="$(date +%s)"
  step_start_msg 2 "OpenClaw gateway check"
  previous_update="$OPENCLAW_UPDATE"
  OPENCLAW_UPDATE=0
  install_openclaw
  OPENCLAW_UPDATE="$previous_update"
  step_done_msg 2 "OpenClaw gateway check" "$step_start"

  step_start="$(date +%s)"
  step_start_msg 3 "Install or update Miloco 2.0"
  install_miloco
  step_done_msg 3 "Install or update Miloco 2.0" "$step_start"

  step_start="$(date +%s)"
  step_start_msg 4 "Verify services and ports"
  verify_install
  step_done_msg 4 "Verify services and ports" "$step_start"
  log_timing_since "Miloco action" "$action_start"
  print_next_actions
}

run_repair_update() {
  local previous_upgrade previous_update previous_extra
  previous_upgrade="$RUN_SYSTEM_UPGRADE"
  previous_update="$OPENCLAW_UPDATE"
  previous_extra="$INSTALL_EXTRA_PLUGINS"
  RUN_SYSTEM_UPGRADE=0
  OPENCLAW_UPDATE=0
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
  if state_has STEP_6_DONE; then
    printf '状态: FINISHED\n'
  else
    printf '状态: EXITED_BUT_INCOMPLETE\n'
  fi
  printf '脚本版本: %s\n' "$SCRIPT_VERSION"
  printf '最后完成步骤: %s\n' "$(state_last_done)"
  printf '下一步: %s\n' "$(state_next_step)"
  printf '状态文件: %s\n' "$STATE_FILE"
  printf '日志文件: %s\n' "$LOG_FILE"
  if ! state_has STEP_6_DONE; then
    printf '建议继续命令: %s\n' "$(recommended_continue_command)"
  fi
  verify_install
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

  dispatch_action "$INSTALL_ACTION"
}

main "$@"
