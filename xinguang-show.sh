#!/usr/bin/env bash
# 馨光门市演示引擎：逐景换色 + 音箱播报，零大模型调用，可随时停止。
set -Eeuo pipefail
set +x

XINGUANG_SHOW_VERSION="1.0.0"

PID_FILE="/tmp/xinguang-show.pid"
STATUS_FILE="/tmp/xinguang-show.status"
LOG_FILE="/tmp/xinguang-show.log"
MILOCO_CONFIG_FILE="$HOME/.openclaw/miloco/config.json"
WAINFORT_ENV_FILE="$HOME/wainfort-light/.env"
MILOCO_API_URL="http://127.0.0.1:1810"
WAINFORT_API_URL="http://127.0.0.1:1888"
LIGHT_ONLY_SCENE_SECONDS=12
# 演练模式默认不等待；测试进程管理分支时可设 XINGUANG_SHOW_DRY_RUN_STEP=<秒> 逐景等待。
DRY_RUN_STEP_SECONDS="${XINGUANG_SHOW_DRY_RUN_STEP:-0}"

say() { printf '%s\n' "$*"; }
log() { printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$LOG_FILE" 2>/dev/null || true; }

resolve_show_dir() {
  local script_dir candidate
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
  for candidate in "${XINGUANG_SHOW_DIR:-}" "$script_dir/shows" "$HOME/xinguang-ai-light/shows"; do
    [[ -n "$candidate" && -d "$candidate" ]] || continue
    printf '%s\n' "$candidate"
    return 0
  done
  return 1
}

char_count() {
  printf '%s' "$1" | python3 -c 'import sys; print(len(sys.stdin.buffer.read().decode("utf-8", "ignore")))'
}

valid_color() { [[ "$1" =~ ^#[0-9A-Fa-f]{6}$ ]]; }

valid_pair() {
  local c0 c1 rest
  IFS=',' read -r c0 c1 rest <<<"$1"
  [[ -z "${rest:-}" ]] || return 1
  valid_color "${c0:-}" && valid_color "${c1:-}"
}

# 解析秀文件：第 1 行「#秀名<TAB>显示名」，其后每行「文案<TAB>主色对<TAB>辅色对」。
# 色值不合法的景整景跳过并中文告警，绝不把残值发给设备。
SHOW_DISPLAY_NAME=""
SCENE_TEXTS=()
SCENE_MAINS=()
SCENE_ALTS=()
load_show() {
  local file="$1" lineno=0 raw_scene=0 text main alt
  SHOW_DISPLAY_NAME=""
  SCENE_TEXTS=()
  SCENE_MAINS=()
  SCENE_ALTS=()
  while IFS=$'\t' read -r text main alt || [[ -n "${text:-}" ]]; do
    lineno=$((lineno + 1))
    if (( lineno == 1 )); then
      if [[ "$text" != "#秀名" || -z "${main:-}" ]]; then
        say "秀文件格式不对：第 1 行应为「#秀名<TAB>显示名」"
        return 1
      fi
      SHOW_DISPLAY_NAME="$main"
      continue
    fi
    [[ -n "${text:-}" ]] || continue
    raw_scene=$((raw_scene + 1))
    if [[ -z "${main:-}" || -z "${alt:-}" ]]; then
      say "提醒：第${raw_scene}景缺少色对，整景已跳过，未向设备下发"
      log "第${raw_scene}景缺少色对，整景跳过"
      continue
    fi
    if ! valid_pair "$main" || ! valid_pair "$alt"; then
      say "提醒：第${raw_scene}景色值不合法（要求 #RRGGBB,#RRGGBB），整景已跳过，未向设备下发"
      log "第${raw_scene}景色值不合法，整景跳过"
      continue
    fi
    SCENE_TEXTS+=("$text")
    SCENE_MAINS+=("$main")
    SCENE_ALTS+=("$alt")
  done <"$file"

  if (( ${#SCENE_TEXTS[@]} == 0 )); then
    say "这个秀里没有可用的景，无法播放"
    return 1
  fi
  return 0
}

list_shows() {
  local show_dir file base first_field display
  if ! show_dir="$(resolve_show_dir)"; then
    say "还没有找到秀目录，请先完成馨光部署"
    return 1
  fi
  local found=0
  for file in "$show_dir"/*.show; do
    [[ -f "$file" ]] || continue
    IFS=$'\t' read -r first_field display _ <"$file" || true
    [[ "$first_field" == "#秀名" && -n "${display:-}" ]] || continue
    if (( found == 0 )); then
      say "可播放的场景秀："
      found=1
    fi
    base="$(basename "$file" .show)"
    say "  ${base}  ——  ${display}"
  done
  if (( found == 0 )); then
    say "秀目录 $show_dir 里还没有可用的秀"
    return 1
  fi
  say "播放请执行：xinguang-show <秀名>；演练请执行：xinguang-show --dry-run <秀名>"
}

running_pid() {
  local pid
  [[ -f "$PID_FILE" ]] || return 1
  pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  printf '%s\n' "$pid"
}

current_scene_no() {
  local name display idx total
  IFS=$'\t' read -r name display idx total _ <"$STATUS_FILE" 2>/dev/null || true
  printf '%s\n' "${idx:-?}"
}

cmd_status() {
  local pid name display idx total
  if pid="$(running_pid)"; then
    IFS=$'\t' read -r name display idx total _ <"$STATUS_FILE" 2>/dev/null || true
    if [[ -n "${display:-}" ]]; then
      say "演示正在播放：《${display}》第 ${idx:-?}/${total:-?} 景"
    else
      say "演示正在播放中"
    fi
  else
    rm -f "$PID_FILE" "$STATUS_FILE"
    say "当前没有正在播放的演示"
  fi
}

cmd_stop() {
  local pid
  if pid="$(running_pid)"; then
    # 只按 PID 文件精确停止，严禁 pkill 按名匹配
    kill "$pid" 2>/dev/null || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.2
    done
    rm -f "$PID_FILE" "$STATUS_FILE"
    say "已停止演示，灯光停在当前景"
  else
    rm -f "$PID_FILE" "$STATUS_FILE"
    say "当前没有正在播放的演示"
  fi
}

read_miloco_token() {
  [[ -f "$MILOCO_CONFIG_FILE" ]] || return 1
  python3 - "$MILOCO_CONFIG_FILE" <<'PY' 2>/dev/null
import json
import sys
with open(sys.argv[1], encoding="utf-8") as handle:
    token = json.load(handle)["server"]["token"]
if not token:
    raise SystemExit(1)
print(token)
PY
}

# 输出 did<TAB>名称，仅保留 model=wainft.light.rgbcwy 且在线的设备
discover_lights() {
  local token
  token="$(read_miloco_token)" || return 1
  curl -fsS --max-time 20 \
    -H "Authorization: Bearer $token" \
    "$MILOCO_API_URL/api/miot/home" 2>/dev/null |
    python3 -c '
import json
import sys

def walk(value):
    if isinstance(value, dict):
        yield value
        for child in value.values():
            yield from walk(child)
    elif isinstance(value, list):
        for child in value:
            yield from walk(child)

def truthy(value):
    if isinstance(value, bool):
        return value
    return str(value).lower() in ("1", "true", "online", "yes", "在线")

seen = set()
try:
    data = json.load(sys.stdin)
except Exception:
    raise SystemExit(1)
for item in walk(data):
    if not isinstance(item, dict):
        continue
    did = item.get("did")
    if not did or did in seen:
        continue
    if item.get("model") != "wainft.light.rgbcwy":
        continue
    if not truthy(item.get("online", False)):
        continue
    seen.add(did)
    name = item.get("name") or "未命名灯光"
    print(f"{did}\t{name}")
'
}

light_is_on() {
  local did="$1" output
  output="$(PATH="$HOME/.local/bin:$PATH" miloco-cli device props "$did" prop.2.1 2>/dev/null || true)"
  [[ -n "$output" ]] || { printf 'unknown\n'; return 0; }
  printf '%s' "$output" | python3 -c '
import json
import re
import sys

raw = sys.stdin.read()

def walk(value):
    if isinstance(value, dict):
        for key, child in value.items():
            if key in ("prop.2.1", "on", "power"):
                yield child
            yield from walk(child)
    elif isinstance(value, list):
        for child in value:
            yield from walk(child)

values = []
try:
    values = list(walk(json.loads(raw)))
except json.JSONDecodeError:
    pass

for value in values:
    if isinstance(value, bool):
        print("true" if value else "false")
        raise SystemExit
    lowered = str(value).strip().lower()
    if lowered in ("true", "1", "on", "开启", "已开启"):
        print("true")
        raise SystemExit
    if lowered in ("false", "0", "off", "关闭", "已关闭"):
        print("false")
        raise SystemExit

if re.search(r"(?:prop\.2\.1|on|power)[^\n]{0,80}\btrue\b", raw, re.I):
    print("true")
elif re.search(r"(?:prop\.2\.1|on|power)[^\n]{0,80}\bfalse\b", raw, re.I):
    print("false")
else:
    print("unknown")
' 2>/dev/null || printf 'unknown\n'
}

# 从 miloco-cli device catalog 输出里找第一台带 play-text 能力的音箱
discover_speaker() {
  local output
  output="$(PATH="$HOME/.local/bin:$PATH" miloco-cli device catalog 2>/dev/null || true)"
  [[ -n "$output" ]] || return 1
  printf '%s' "$output" | python3 -c '
import json
import re
import sys

raw = sys.stdin.read()

def emit(did):
    did = str(did).strip()
    if did:
        print(did)
        raise SystemExit(0)

data = None
try:
    data = json.loads(raw)
except Exception:
    data = None

if data is not None:
    def walk(value):
        if isinstance(value, dict):
            yield value
            for child in value.values():
                yield from walk(child)
        elif isinstance(value, list):
            for child in value:
                yield from walk(child)
    for item in walk(data):
        if not isinstance(item, dict):
            continue
        did = item.get("did") or item.get("device_id") or item.get("deviceId")
        if not did:
            continue
        if "play-text" in json.dumps(item, ensure_ascii=False):
            emit(did)
else:
    did_re = re.compile(r"did[\"\x27\s:=]+([A-Za-z0-9._\-]+)")
    current = ""
    for line in raw.splitlines():
        match = did_re.search(line)
        if match:
            current = match.group(1)
        if "play-text" not in line:
            continue
        if match:
            emit(match.group(1))
        fields = line.split()
        if fields and fields[0] != "play-text" and re.fullmatch(r"[A-Za-z0-9._\-]+", fields[0]):
            emit(fields[0])
        if current:
            emit(current)
raise SystemExit(1)
' 2>/dev/null
}

apply_light_color() {
  local did="$1" pair="$2" c0 c1 body
  IFS=',' read -r c0 c1 <<<"$pair"
  body="$(python3 -c 'import json, sys; print(json.dumps({"did": sys.argv[1], "color0": sys.argv[2], "color1": sys.argv[3], "brightness": 100}))' "$did" "$c0" "$c1")"
  if curl -fsS --max-time 20 -X POST "$WAINFORT_API_URL/api/generate" \
    -H "Authorization: Bearer ${WAINFORT_API_TOKEN:-}" \
    -H "Content-Type: application/json" \
    -d "$body" >/dev/null 2>&1; then
    log "灯 $did 换色成功（$pair）"
    return 0
  fi
  log "灯 $did 换色失败（$pair）"
  return 1
}

speak_text() {
  local did="$1" text="$2"
  if PATH="$HOME/.local/bin:$PATH" miloco-cli device action "$did" play-text "$text" >/dev/null 2>&1; then
    log "音箱 $did 播报成功"
    return 0
  fi
  log "音箱 $did 播报失败"
  return 1
}

scene_wait_seconds() {
  local text="$1" has_speaker="$2" chars
  if [[ "$has_speaker" == 1 ]]; then
    chars="$(char_count "$text")"
    printf '%s\n' "$(( (chars + 3) / 4 + 2 ))"
  else
    printf '%s\n' "$LIGHT_ONLY_SCENE_SECONDS"
  fi
}

interruptible_sleep() {
  local seconds="$1"
  [[ "$seconds" =~ ^[0-9]+$ ]] && (( seconds > 0 )) || return 0
  sleep "$seconds" &
  wait $! || true
}

CURRENT_SCENE=0
cleanup_runtime_files() { rm -f "$PID_FILE" "$STATUS_FILE"; }
on_stop_signal() {
  log "收到停止指令，演示在第${CURRENT_SCENE}景停止，灯光停在当前景"
  cleanup_runtime_files
  trap - EXIT
  exit 0
}

# 播放主循环。dry_run=1 时只打印动作、不调设备。
run_playback() {
  local show_name="$1" dry_run="$2" show_dir show_file
  local has_speaker=0 speaker_did="" total idx text main alt wait_s
  local lights=() names=() off_names=() line did name state pair

  if ! show_dir="$(resolve_show_dir)"; then
    say "还没有找到秀目录，请先完成馨光部署"
    exit 1
  fi
  show_file="$show_dir/$show_name.show"
  if [[ ! -f "$show_file" ]]; then
    say "找不到名为「$show_name」的秀"
    list_shows || true
    exit 1
  fi
  load_show "$show_file" || exit 1
  total=${#SCENE_TEXTS[@]}

  printf '%s\n' "$$" >"$PID_FILE"
  trap on_stop_signal TERM INT
  trap cleanup_runtime_files EXIT

  if [[ "$dry_run" == 1 ]]; then
    say "演练模式：只打印动作，不连接、不控制任何设备"
    has_speaker=1
  else
    # 灯光服务令牌（不上屏、不落日志）
    if [[ -f "$WAINFORT_ENV_FILE" ]]; then
      set -a
      # shellcheck disable=SC1090
      . "$WAINFORT_ENV_FILE"
      set +a
    fi
    if [[ -z "${WAINFORT_API_TOKEN:-}" ]]; then
      say "灯光服务配置缺失，请先完成馨光部署再播放"
      exit 1
    fi

    say "正在查找门市的馨光灯……"
    local discovery
    if ! discovery="$(discover_lights)" || [[ -z "$discovery" ]]; then
      say "没有发现在线的馨光灯，请确认灯已通电在线后再播放"
      exit 1
    fi
    while IFS=$'\t' read -r did name; do
      [[ -n "$did" ]] || continue
      state="$(light_is_on "$did")"
      if [[ "$state" == "true" ]]; then
        lights+=("$did")
        names+=("${name:-$did}")
      else
        off_names+=("${name:-$did}")
      fi
    done <<<"$discovery"

    if (( ${#off_names[@]} > 0 )); then
      say "以下灯当前是关闭状态，不参与本次演示：${off_names[*]}"
    fi
    if (( ${#lights[@]} == 0 )); then
      say "请先打开门市的馨光灯再播放"
      exit 1
    fi
    say "本次演示将使用 ${#lights[@]} 盏灯：${names[*]}"

    if speaker_did="$(discover_speaker)" && [[ -n "$speaker_did" ]]; then
      has_speaker=1
      say "已找到可播报的音箱，演示将带语音讲解"
    else
      has_speaker=0
      speaker_did=""
      say "没有找到可播报的音箱，本次为纯灯光模式（每景 ${LIGHT_ONLY_SCENE_SECONDS} 秒）"
    fi
  fi

  say "开始播放《${SHOW_DISPLAY_NAME}》，共 ${total} 景"
  log "开始播放《${SHOW_DISPLAY_NAME}》（$show_name），共 ${total} 景，dry_run=$dry_run"

  local dry_total=0
  for (( idx = 0; idx < total; idx++ )); do
    CURRENT_SCENE=$((idx + 1))
    text="${SCENE_TEXTS[$idx]}"
    main="${SCENE_MAINS[$idx]}"
    alt="${SCENE_ALTS[$idx]}"
    wait_s="$(scene_wait_seconds "$text" "$has_speaker")"
    printf '%s\t%s\t%s\t%s\n' "$show_name" "$SHOW_DISPLAY_NAME" "$CURRENT_SCENE" "$total" >"$STATUS_FILE"

    if [[ "$dry_run" == 1 ]]; then
      say "第 ${CURRENT_SCENE}/${total} 景｜主色对 ${main}｜辅色对 ${alt}｜估算 ${wait_s} 秒"
      say "  播报：${text}"
      dry_total=$((dry_total + wait_s))
      interruptible_sleep "$DRY_RUN_STEP_SECONDS"
      continue
    fi

    say "第 ${CURRENT_SCENE}/${total} 景开始"
    log "第 ${CURRENT_SCENE}/${total} 景：主色对 ${main}，辅色对 ${alt}，等待 ${wait_s} 秒"
    local i
    for (( i = 0; i < ${#lights[@]}; i++ )); do
      if (( i % 2 == 0 )); then
        pair="$main"
      else
        pair="$alt"
      fi
      apply_light_color "${lights[$i]}" "$pair" || true
    done
    if [[ "$has_speaker" == 1 ]]; then
      speak_text "$speaker_did" "$text" || true
    fi
    interruptible_sleep "$wait_s"
  done

  if [[ "$dry_run" == 1 ]]; then
    say "演练完成：共 ${total} 景，按有音箱估算总时长约 ${dry_total} 秒；纯灯光模式约 $((total * LIGHT_ONLY_SCENE_SECONDS)) 秒"
  else
    say "《${SHOW_DISPLAY_NAME}》播放完成，灯光停在最后一景"
  fi
  log "《${SHOW_DISPLAY_NAME}》播放结束，灯光停在最后一景"
}

guard_duplicate() {
  local pid scene
  if pid="$(running_pid)"; then
    scene="$(current_scene_no)"
    say "演示正在播放（第${scene}景），如需重新开始请先执行 xinguang-show --stop"
    exit 0
  fi
  rm -f "$PID_FILE" "$STATUS_FILE"
}

cmd_play() {
  local show_name="$1" show_dir show_file
  guard_duplicate
  if ! show_dir="$(resolve_show_dir)"; then
    say "还没有找到秀目录，请先完成馨光部署"
    exit 1
  fi
  show_file="$show_dir/$show_name.show"
  if [[ ! -f "$show_file" ]]; then
    say "找不到名为「$show_name」的秀"
    list_shows || true
    exit 1
  fi
  load_show "$show_file" || exit 1
  nohup "${BASH_SOURCE[0]}" --player "$show_name" >>"$LOG_FILE" 2>&1 &
  disown 2>/dev/null || true
  say "已开始播放《${SHOW_DISPLAY_NAME}》，共 ${#SCENE_TEXTS[@]} 景"
  say "查看进度：xinguang-show --status；停止：xinguang-show --stop"
}

usage() {
  cat <<'EOF'
用法：
  xinguang-show                 列出可播放的场景秀
  xinguang-show <秀名>          播放指定的秀（后台推进，可随时停止）
  xinguang-show --dry-run <秀名> 演练：只打印动作，不控制设备
  xinguang-show --status        查看是否在播、播到第几景
  xinguang-show --stop          停止播放，灯光停在当前景
EOF
}

main() {
  command -v python3 >/dev/null 2>&1 || { say "缺少 python3，无法运行演示引擎，请联系工作人员处理"; exit 1; }
  case "${1:-}" in
    "")
      list_shows
      ;;
    --status)
      cmd_status
      ;;
    --stop)
      cmd_stop
      ;;
    --dry-run)
      [[ -n "${2:-}" ]] || { usage; exit 1; }
      guard_duplicate
      run_playback "$2" 1
      ;;
    --player)
      # 内部入口：cmd_play 派生的后台播放进程
      [[ -n "${2:-}" ]] || exit 1
      run_playback "$2" 0
      ;;
    --help|-h)
      usage
      ;;
    --*)
      usage
      exit 1
      ;;
    *)
      cmd_play "$1"
      ;;
  esac
}

main "$@"
