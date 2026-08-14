#!/usr/bin/env bash
# 馨光门市演示引擎：逐景换色 + 音箱播报，零大模型调用，可随时停止。
set -Eeuo pipefail
set +x

XINGUANG_SHOW_VERSION="1.5.1"

PID_FILE="/tmp/xinguang-show.pid"
STATUS_FILE="/tmp/xinguang-show.status"
LOG_FILE="/tmp/xinguang-show.log"
MILOCO_CONFIG_FILE="$HOME/.openclaw/miloco/config.json"
WAINFORT_ENV_FILE="$HOME/wainfort-light/.env"
MILOCO_API_URL="http://127.0.0.1:1810"
WAINFORT_API_URL="http://127.0.0.1:1888"
LIGHT_ONLY_SCENE_SECONDS=12
# 自定义秀目录：位于安装目录之外，引擎/安装器更新不覆盖
CUSTOM_SHOW_DIR="$HOME/wainfort-light/shows"
# 演练模式默认不等待；测试进程管理分支时可设 XINGUANG_SHOW_DRY_RUN_STEP=<秒> 逐景等待。
DRY_RUN_STEP_SECONDS="${XINGUANG_SHOW_DRY_RUN_STEP:-0}"
# 测试/演练可注入设备清单：XINGUANG_SHOW_MOCK_DEVICES 指向 TSV 文件，
# 每行：did<TAB>名称<TAB>房间<TAB>model<TAB>on(true/false)<TAB>能力(逗号分隔，含 play-text 即可播报)

say() { printf '%s\n' "$*"; }
log() { printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$LOG_FILE" 2>/dev/null || true; }

preset_show_dir() {
  local script_dir candidate
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
  for candidate in "${XINGUANG_SHOW_DIR:-}" "$script_dir/shows" "$HOME/xinguang-ai-light/shows"; do
    [[ -n "$candidate" && -d "$candidate" ]] || continue
    printf '%s\n' "$candidate"
    return 0
  done
  return 1
}

# 按秀名找文件：自定义目录优先，其次预置目录
find_show_file() {
  local name="$1" preset
  if [[ -f "$CUSTOM_SHOW_DIR/$name.show" ]]; then
    printf '%s\n' "$CUSTOM_SHOW_DIR/$name.show"
    return 0
  fi
  if preset="$(preset_show_dir)" && [[ -f "$preset/$name.show" ]]; then
    printf '%s\n' "$preset/$name.show"
    return 0
  fi
  return 1
}

mock_devices_ready() {
  [[ -n "${XINGUANG_SHOW_MOCK_DEVICES:-}" && -f "${XINGUANG_SHOW_MOCK_DEVICES:-}" ]]
}

# 房间匹配：设备房间与目标房间互为包含即命中（如「门市」匹配「门市茶区」）
room_matches() {
  local dev_room="$1" want_room="$2"
  [[ -z "$want_room" ]] && return 0
  [[ -n "$dev_room" ]] || return 1
  [[ "$dev_room" == *"$want_room"* || "$want_room" == *"$dev_room"* ]]
}

# 逗号分隔多值拆分：去掉每段首尾空白并去重，逐行输出
split_csv() {
  local csv="$1" tok seen=""
  local parts=()
  IFS=',' read -r -a parts <<<"$csv"
  for tok in ${parts[@]+"${parts[@]}"}; do
    tok="${tok#"${tok%%[![:space:]]*}"}"
    tok="${tok%"${tok##*[![:space:]]}"}"
    [[ -n "$tok" ]] || continue
    case "$seen" in *$'\t'"$tok"$'\t'*) continue ;; esac
    seen="${seen}"$'\t'"$tok"$'\t'
    printf '%s\n' "$tok"
  done
}

# 多值房间匹配：设备房间与任一目标房间互含即命中；目标为空表示不过滤
room_matches_any() {
  local dev_room="$1" rooms_csv="$2" r
  [[ -z "$rooms_csv" ]] && return 0
  while IFS= read -r r; do
    room_matches "$dev_room" "$r" && return 0
  done < <(split_csv "$rooms_csv")
  return 1
}

# 把逗号分隔多值拼成「甲」「乙」样式，用于中文提示
quote_tokens() {
  local csv="$1" tok out=""
  while IFS= read -r tok; do
    out="${out}「${tok}」"
  done < <(split_csv "$csv")
  printf '%s\n' "$out"
}

to_lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# --lamp 名称匹配：设备名与指定名互为包含（大小写无关）；did 精确另在解析处优先处理
lamp_name_matches() {
  local token="$1" name="$2" lt ln
  lt="$(to_lower "$token")"
  ln="$(to_lower "$name")"
  [[ -n "$lt" && -n "$ln" ]] || return 1
  [[ "$ln" == *"$lt"* || "$lt" == *"$ln"* ]]
}

# 按多值房间过滤设备清单（did<TAB>名称<TAB>房间），逐行输出命中的
filter_lights_by_rooms() {
  local discovery="$1" rooms_csv="$2" did name room
  while IFS=$'\t' read -r did name room; do
    [[ -n "$did" ]] || continue
    room_matches_any "${room:-}" "$rooms_csv" || continue
    printf '%s\t%s\t%s\n' "$did" "$name" "$room"
  done <<<"$discovery"
}

# 解析 --lamp 指定：候选集为已按房间过滤的清单（did<TAB>名称<TAB>房间）。
# 每个指定值：did 精确命中优先；否则名称互含（大小写无关）。
# 无命中或名称多命中都失败（调用方以退出码 1 结束）；多命中时打印候选清单（名称｜房间）。
# 成功时命中并集（按 did 去重）写入 SELECTED_LINES，一行一灯。
SELECTED_LINES=""
resolve_lamp_selection() {
  local lamps_csv="$1" candidates="$2" rooms_csv="${3:-}" token did name room
  local matched count picked_dids=$'\n'
  SELECTED_LINES=""
  while IFS= read -r token; do
    matched=""
    count=0
    # did 精确命中优先，避免 did 再被名称互含误判为多命中
    while IFS=$'\t' read -r did name room; do
      [[ -n "$did" ]] || continue
      if [[ "$token" == "$did" ]]; then
        matched="${did}"$'\t'"${name}"$'\t'"${room}"
        count=1
        break
      fi
    done <<<"$candidates"
    if (( count == 0 )); then
      while IFS=$'\t' read -r did name room; do
        [[ -n "$did" ]] || continue
        lamp_name_matches "$token" "$name" || continue
        matched="${matched:+$matched$'\n'}${did}"$'\t'"${name}"$'\t'"${room}"
        count=$((count + 1))
      done <<<"$candidates"
    fi
    if (( count == 0 )); then
      if [[ -n "$rooms_csv" ]]; then
        say "在$(quote_tokens "$rooms_csv")房间里没有找到名为「${token}」的馨光灯，请检查灯名或房间范围"
      else
        say "没有找到名为「${token}」的馨光灯，请检查灯名或 did"
      fi
      return 1
    fi
    if (( count > 1 )); then
      say "「${token}」命中了多盏灯，请用更完整的名称或 did 指定："
      while IFS=$'\t' read -r did name room; do
        say "  ${name}｜${room:-未知房间}"
      done <<<"$matched"
      return 1
    fi
    IFS=$'\t' read -r did name room <<<"$matched"
    case "$picked_dids" in *$'\n'"$did"$'\n'*) continue ;; esac
    picked_dids="${picked_dids}${did}"$'\n'
    SELECTED_LINES="${SELECTED_LINES:+$SELECTED_LINES$'\n'}${matched}"
  done < <(split_csv "$lamps_csv")
  return 0
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

# 色距硬校验（纯本地）：色对内部 color0 与 color1 的 RGB 欧氏距离 >=110（0-441 尺度），
# 渐变必须一眼可辨（60 档的同色系深浅在灯上近似单色，产品方裁决提标）。
# 输出为空表示通过；不过时输出实际距离。
scene_color_report() {
  python3 - "$1" <<'PY'
import sys

def rgb(color):
    return tuple(int(color[i:i + 2], 16) for i in (1, 3, 5))

first, second = sys.argv[1].split(",")
p, q = rgb(first), rgb(second)
d = sum((x - y) ** 2 for x, y in zip(p, q)) ** 0.5
EPS = 1e-9  # 浮点容差，避免恰在阈值上的配色被误拒
if d < 110 - EPS:
    print(f"{d:.0f}")
PY
}

# 解析秀文件：第 1 行「#秀名<TAB>显示名」，其后每行一景，兼容两种格式：
#   2 列「文案<TAB>色对」；3 列旧格式「文案<TAB>色对<TAB>辅色对」（第 3 列忽略，不校验不下发）。
# 同一房间所有灯统一使用该景色对；色值不合法的景整景跳过并中文告警，绝不把残值发给设备。
SHOW_DISPLAY_NAME=""
SCENE_TEXTS=()
SCENE_MAINS=()
SHOW_SKIPPED_TOTAL=0
load_show() {
  local file="$1" lineno=0 raw_scene=0 color_rejected=0 text main rest
  local report
  SHOW_DISPLAY_NAME=""
  SCENE_TEXTS=()
  SCENE_MAINS=()
  SHOW_SKIPPED_TOTAL=0
  while IFS=$'\t' read -r text main rest || [[ -n "${text:-}" ]]; do
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
    if [[ -z "${main:-}" ]]; then
      say "提醒：第${raw_scene}景缺少色对，整景已跳过，未向设备下发"
      log "第${raw_scene}景缺少色对，整景跳过"
      SHOW_SKIPPED_TOTAL=$((SHOW_SKIPPED_TOTAL + 1))
      continue
    fi
    if ! valid_pair "$main"; then
      say "提醒：第${raw_scene}景色值不合法（要求 #RRGGBB,#RRGGBB），整景已跳过，未向设备下发"
      log "第${raw_scene}景色值不合法，整景跳过"
      SHOW_SKIPPED_TOTAL=$((SHOW_SKIPPED_TOTAL + 1))
      continue
    fi

    # 色距硬校验：色对内部距离不足则整景拒播
    report="$(scene_color_report "$main" 2>/dev/null || true)"
    if [[ -n "$report" ]]; then
      color_rejected=$((color_rejected + 1))
      SHOW_SKIPPED_TOTAL=$((SHOW_SKIPPED_TOTAL + 1))
      say "提醒：第${raw_scene}景色对内部两色过近（RGB 距离仅${report}，需110以上），渐变会看不出来，整景拒播；请改选对撞色系（如红配石青、黄配群青）再试"
      log "第${raw_scene}景色距校验不过，整景拒播"
      continue
    fi

    SCENE_TEXTS+=("$text")
    SCENE_MAINS+=("$main")
  done <"$file"

  # 色距拒播景数达到总景数一半即终止整场
  if (( raw_scene > 0 && color_rejected * 2 >= raw_scene )); then
    say "本场配色对比不足（${raw_scene}景中${color_rejected}景被拒播），请整体重新配色"
    return 1
  fi
  if (( ${#SCENE_TEXTS[@]} == 0 )); then
    say "这个秀里没有可用的景，无法播放"
    return 1
  fi
  return 0
}

show_display_of() {
  local first_field display
  IFS=$'\t' read -r first_field display _ <"$1" 2>/dev/null || true
  [[ "$first_field" == "#秀名" && -n "${display:-}" ]] || return 1
  printf '%s\n' "$display"
}

list_shows() {
  local preset_dir file base display found=0
  local custom_names=()

  if [[ -d "$CUSTOM_SHOW_DIR" ]]; then
    for file in "$CUSTOM_SHOW_DIR"/*.show; do
      [[ -f "$file" ]] || continue
      display="$(show_display_of "$file")" || continue
      if (( found == 0 )); then
        say "可播放的场景秀："
        found=1
      fi
      if (( ${#custom_names[@]} == 0 )); then
        say "【自定义】"
      fi
      base="$(basename "$file" .show)"
      custom_names+=("$base")
      say "  ${base}  ——  ${display}"
    done
  fi

  if preset_dir="$(preset_show_dir)"; then
    local printed_header=0 name skip
    for file in "$preset_dir"/*.show; do
      [[ -f "$file" ]] || continue
      display="$(show_display_of "$file")" || continue
      base="$(basename "$file" .show)"
      skip=0
      for name in ${custom_names[@]+"${custom_names[@]}"}; do
        [[ "$name" == "$base" ]] && { skip=1; break; }
      done
      (( skip )) && continue
      if (( found == 0 )); then
        say "可播放的场景秀："
        found=1
      fi
      if (( printed_header == 0 )); then
        say "【预置】"
        printed_header=1
      fi
      say "  ${base}  ——  ${display}"
    done
  fi

  if (( found == 0 )); then
    say "还没有可播放的秀，请先完成馨光部署或先保存一个自定义秀"
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
  IFS=$'\t' read -r name display idx total _ 2>/dev/null <"$STATUS_FILE" || true
  printf '%s\n' "${idx:-?}"
}

cmd_status() {
  local pid name display idx total
  if pid="$(running_pid)"; then
    IFS=$'\t' read -r name display idx total _ 2>/dev/null <"$STATUS_FILE" || true
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

# 输出 did<TAB>名称<TAB>房间，仅保留 model=wainft.light.rgbcwy 且在线的设备
# 房间优先取 room_name，缺省回退 room 字段
discover_lights() {
  if mock_devices_ready; then
    awk -F'\t' '$4 == "wainft.light.rgbcwy" { print $1 "\t" $2 "\t" $3 }' "$XINGUANG_SHOW_MOCK_DEVICES"
    return 0
  fi
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
    room = item.get("room_name") or item.get("room") or ""
    print(f"{did}\t{name}\t{room}")
'
}

light_is_on() {
  local did="$1" output
  if mock_devices_ready; then
    awk -F'\t' -v want="$did" '$1 == want { print ($5 == "true" ? "true" : "false"); found = 1 } END { if (!found) print "unknown" }' "$XINGUANG_SHOW_MOCK_DEVICES"
    return 0
  fi
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

# 音箱发现（真机实证 catalog 无动作列且漏设备，已弃用）：
# 与灯同源读 /api/miot/home，按房间互含过滤；候选条件 category=="speaker"
# （条目无 category 字段时回退「名称含音箱」）；再逐台 miloco-cli device spec
# 确认含 play-text 能力，取第一台确认的。$1 非空时按房间过滤。
discover_speaker() {
  local want_room="${1:-}" candidates did name token
  if mock_devices_ready; then
    # mock 模式：能力列含 play-text 即命中，不调 spec
    local room model on caps
    while IFS=$'\t' read -r did name room model on caps; do
      [[ -n "$did" && "$caps" == *play-text* ]] || continue
      room_matches "$room" "$want_room" || continue
      printf '%s\n' "$did"
      return 0
    done <"$XINGUANG_SHOW_MOCK_DEVICES"
    return 1
  fi

  token="$(read_miloco_token)" || return 1
  candidates="$(curl -fsS --max-time 20 \
    -H "Authorization: Bearer $token" \
    "$MILOCO_API_URL/api/miot/home" 2>/dev/null |
    python3 -c '
import json
import sys

want_room = sys.argv[1] if len(sys.argv) > 1 else ""

def walk(value):
    if isinstance(value, dict):
        yield value
        for child in value.values():
            yield from walk(child)
    elif isinstance(value, list):
        for child in value:
            yield from walk(child)

try:
    data = json.load(sys.stdin)
except Exception:
    raise SystemExit(1)

seen = set()
for item in walk(data):
    if not isinstance(item, dict):
        continue
    did = item.get("did")
    if not did or did in seen:
        continue
    if item.get("model") == "wainft.light.rgbcwy":
        continue
    name = str(item.get("name") or "")
    room = str(item.get("room_name") or item.get("room") or "")
    if want_room and not (room and (want_room in room or room in want_room)):
        continue
    if "category" in item:
        if str(item.get("category")) != "speaker":
            continue
    elif "音箱" not in name:
        continue
    seen.add(did)
    print(f"{did}\t{name or did}")
' "$want_room" 2>/dev/null)" || return 1
  [[ -n "$candidates" ]] || return 1

  while IFS=$'\t' read -r did name; do
    [[ -n "$did" ]] || continue
    # 逐台读设备 spec，确认真的有 play-text 播报能力再选用
    if PATH="$HOME/.local/bin:$PATH" miloco-cli device spec "$did" 2>/dev/null | grep -q "play-text"; then
      printf '%s\n' "$did"
      return 0
    fi
  done <<<"$candidates"
  return 1
}

# 色值 #RRGGBB → uint32 RGB 十进制整数（设备属性 4.93/4.94 的取值格式）
color_to_int() {
  local hex="${1#\#}"
  printf '%s\n' "$((16#$hex))"
}

# 读灯运行模式 prop.4.37（0=音乐律动,1=静态,2=动态）；读不到输出空，
# 调用方走安全侧：不带 4.37、照常下发。
read_led_mode() {
  local did="$1" output
  output="$(PATH="$HOME/.local/bin:$PATH" miloco-cli device props "$did" prop.4.37 2>/dev/null || true)"
  [[ -n "$output" ]] || return 0
  printf '%s' "$output" | python3 -c '
import json
import re
import sys

raw = sys.stdin.read()

def walk(value):
    if isinstance(value, dict):
        for key, child in value.items():
            if key == "prop.4.37":
                yield child
            yield from walk(child)
    elif isinstance(value, list):
        for child in value:
            yield from walk(child)

try:
    for value in walk(json.loads(raw)):
        text = str(value).strip()
        if re.fullmatch(r"\d+", text):
            print(text)
            raise SystemExit
except json.JSONDecodeError:
    pass

match = re.search(r"prop\.4\.37\D{0,40}?(\d+)", raw)
if match:
    print(match.group(1))
' 2>/dev/null || true
}

# 原子下发（1.5.0 根治二次跳变，King 真机双设备目视验收）：
# 色点 prop.4.93/4.94（uint32 RGB 整数）+ 白光亮度等级 prop.4.106=3
# 一次 set_properties 写入、一次渲染。替代旧「generate + 补写 4.106」两步——
# generate 每次触发会把 4.106 重置回 5，补写造成每景二次渲染跳变。
# 写入前回读 4.37 运行模式：非 2（动态）时把 4.37=2 并入同一原子批（仍是一次写入）；
# 已是 2 则不带（避免同值写触发多余处理）；读取失败不带 4.37、照常下发（安全侧）。
# 整灯亮度 prop.2.2 禁写铁律不变：本函数不写任何 2.x 属性。
apply_light_color() {
  local did="$1" pair="$2" c0 c1 c0_int c1_int mode props body miloco_token
  IFS=',' read -r c0 c1 <<<"$pair"
  c0_int="$(color_to_int "$c0")"
  c1_int="$(color_to_int "$c1")"
  if ! miloco_token="$(read_miloco_token)"; then
    log "灯 $did 原子下发失败（未读到 miloco token）"
    return 1
  fi
  props="[{\"iid\":\"prop.4.93\",\"value\":$c0_int},{\"iid\":\"prop.4.94\",\"value\":$c1_int},{\"iid\":\"prop.4.106\",\"value\":3}"
  mode="$(read_led_mode "$did")"
  if [[ -n "$mode" && "$mode" != "2" ]]; then
    props="${props},{\"iid\":\"prop.4.37\",\"value\":2}"
  fi
  # 批尾追加参数提交信号 4.108（modeparasetend）：真机 A/B 实证可把灯膜换景时的
  # 纯色中间帧从"明显"降到"轻微"（设备端渲染行为，彻底平滑需固件支持，已转研发）
  props="${props},{\"iid\":\"prop.4.108\",\"value\":true}]"
  body="{\"type\":\"set_properties\",\"properties\":$props}"
  if curl -fsS --max-time 20 -X POST "$MILOCO_API_URL/api/miot/devices/$did/control" \
    -H "Authorization: Bearer $miloco_token" \
    -H "Content-Type: application/json" \
    -d "$body" >/dev/null 2>&1; then
    log "灯 $did 原子下发成功（色对 $pair，档位 3）"
    return 0
  fi
  log "灯 $did 原子下发失败（色对 $pair）"
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
  # 结束仍在跑的后台作业（并发换色的 curl、可中断等待的 sleep），不留孤儿进程。
  # pkill -P 是按父 PID 精确清理作业的子进程，不是按名匹配，不违反「严禁 pkill 按名」禁令。
  local job_pids jp
  job_pids="$(jobs -p 2>/dev/null || true)"
  if [[ -n "$job_pids" ]]; then
    for jp in $job_pids; do
      pkill -P "$jp" 2>/dev/null || true
      kill "$jp" 2>/dev/null || true
    done
  fi
  cleanup_runtime_files
  trap - EXIT
  exit 0
}

# 设备发现 + 范围过滤：结果写入 LIGHTS/LIGHT_NAMES/OFF_NAMES/SPEAKER_DIDS/HAS_SPEAKER
# $1=--room 多值（逗号分隔，可空）；$2=--lamp 多值（逗号分隔，可空）；同给取交集
LIGHTS=()
LIGHT_NAMES=()
OFF_NAMES=()
SPEAKER_DIDS=()
HAS_SPEAKER=0
discover_for_playback() {
  local want_rooms="$1" want_lamps="${2:-}" discovery filtered did name room state
  local participating_rooms="" speaker_rooms="" sdid s dup r
  LIGHTS=()
  LIGHT_NAMES=()
  OFF_NAMES=()
  SPEAKER_DIDS=()
  HAS_SPEAKER=0

  if [[ -n "$want_rooms" && -n "$want_lamps" ]]; then
    say "正在查找$(quote_tokens "$want_rooms")房间里指定的馨光灯$(quote_tokens "$want_lamps")……"
  elif [[ -n "$want_rooms" ]]; then
    say "正在查找$(quote_tokens "$want_rooms")房间的馨光灯……"
  elif [[ -n "$want_lamps" ]]; then
    say "正在查找指定的馨光灯$(quote_tokens "$want_lamps")……"
  else
    say "正在查找门市的馨光灯……"
  fi
  if ! discovery="$(discover_lights)" || [[ -z "$discovery" ]]; then
    say "没有发现在线的馨光灯，请确认灯已通电在线后再播放"
    return 1
  fi

  # 先按房间过滤（多房间取并集），再解析 --lamp（与房间范围取交集）
  filtered="$(filter_lights_by_rooms "$discovery" "$want_rooms")"
  if [[ -n "$want_lamps" ]]; then
    resolve_lamp_selection "$want_lamps" "$filtered" "$want_rooms" || return 1
    filtered="$SELECTED_LINES"
  fi

  while IFS=$'\t' read -r did name room; do
    [[ -n "$did" ]] || continue
    state="$(light_is_on "$did")"
    if [[ "$state" == "true" ]]; then
      LIGHTS+=("$did")
      LIGHT_NAMES+=("${name:-$did}")
      if [[ -n "${room:-}" ]]; then
        participating_rooms="${participating_rooms:+$participating_rooms,}$room"
      fi
    else
      OFF_NAMES+=("${name:-$did}")
    fi
  done <<<"$filtered"

  if (( ${#OFF_NAMES[@]} > 0 )); then
    say "以下灯当前是关闭状态，不参与本次演示：${OFF_NAMES[*]}"
  fi
  if (( ${#LIGHTS[@]} == 0 )); then
    if [[ -n "$want_lamps" ]]; then
      say "指定的馨光灯当前都没开着，请先打开再播放"
    elif [[ -n "$want_rooms" ]]; then
      say "$(quote_tokens "$want_rooms")房间没有开着的馨光灯，请先打开该房间的馨光灯再播放"
    else
      say "请先打开门市的馨光灯再播放"
    fi
    return 1
  fi
  say "本次演示将使用 ${#LIGHTS[@]} 盏灯：${LIGHT_NAMES[*]}"

  # 音箱选取：
  #   给了 --room：每个指定房间各取一台含 play-text 的音箱（按 did 去重）；
  #   只给 --lamp：按命中灯所在房间并集，规则同上；
  #   都没给：沿用原有「取第一台可用音箱」逻辑，行为完全不变。
  if [[ -n "$want_rooms" ]]; then
    speaker_rooms="$want_rooms"
  elif [[ -n "$want_lamps" ]]; then
    speaker_rooms="$participating_rooms"
  fi
  if [[ -n "$want_rooms" || -n "$want_lamps" ]]; then
    while IFS= read -r r; do
      [[ -n "$r" ]] || continue
      if sdid="$(discover_speaker "$r")" && [[ -n "$sdid" ]]; then
        dup=0
        for s in ${SPEAKER_DIDS[@]+"${SPEAKER_DIDS[@]}"}; do
          [[ "$s" == "$sdid" ]] && { dup=1; break; }
        done
        (( dup )) || SPEAKER_DIDS+=("$sdid")
      else
        say "「${r}」房间没有可播报的音箱"
      fi
    done < <(split_csv "$speaker_rooms")
    if (( ${#SPEAKER_DIDS[@]} > 0 )); then
      HAS_SPEAKER=1
      if (( ${#SPEAKER_DIDS[@]} > 1 )); then
        say "已找到 ${#SPEAKER_DIDS[@]} 台可播报的音箱，演示将带语音讲解"
      else
        say "已找到可播报的音箱，演示将带语音讲解"
      fi
    else
      HAS_SPEAKER=0
      if [[ -n "$want_rooms" ]]; then
        say "该房间没有可播报的音箱，本次为纯灯光模式（每景 ${LIGHT_ONLY_SCENE_SECONDS} 秒）"
      else
        say "没有找到可播报的音箱，本次为纯灯光模式（每景 ${LIGHT_ONLY_SCENE_SECONDS} 秒）"
      fi
    fi
  else
    if sdid="$(discover_speaker "")" && [[ -n "$sdid" ]]; then
      SPEAKER_DIDS+=("$sdid")
      HAS_SPEAKER=1
      say "已找到可播报的音箱，演示将带语音讲解"
    else
      HAS_SPEAKER=0
      say "没有找到可播报的音箱，本次为纯灯光模式（每景 ${LIGHT_ONLY_SCENE_SECONDS} 秒）"
    fi
  fi
  return 0
}

# 播放主循环。dry_run=1 时只打印动作、不调设备。
run_playback() {
  local show_name="$1" dry_run="$2" want_room="${3:-}" want_lamp="${4:-}" show_file
  local has_speaker=0 total idx text main wait_s sdid
  local lights=() names=() speaker_dids=()

  if ! show_file="$(find_show_file "$show_name")"; then
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
    say "演练模式：只打印动作，不控制任何设备"
    if [[ -n "$want_room" || -n "$want_lamp" ]] || mock_devices_ready; then
      # 演练下也走发现与范围过滤（真实或 mock 注入清单），但绝不下发命令
      discover_for_playback "$want_room" "$want_lamp" || exit 1
      has_speaker="$HAS_SPEAKER"
    else
      has_speaker=1
    fi
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

    discover_for_playback "$want_room" "$want_lamp" || exit 1
    lights=(${LIGHTS[@]+"${LIGHTS[@]}"})
    names=(${LIGHT_NAMES[@]+"${LIGHT_NAMES[@]}"})
    has_speaker="$HAS_SPEAKER"
    speaker_dids=(${SPEAKER_DIDS[@]+"${SPEAKER_DIDS[@]}"})
  fi

  say "开始播放《${SHOW_DISPLAY_NAME}》，共 ${total} 景"
  log "开始播放《${SHOW_DISPLAY_NAME}》（$show_name），共 ${total} 景，dry_run=$dry_run"

  local dry_total=0
  # 开场白：有音箱时先播报、等 6 秒再进第一景；纯灯光模式跳过
  local opening_text="欢迎体验馨光 AI 淡彩光。每一景，都是人工智能为您设计的淡彩光渐变灯光。接下来为您演示《${SHOW_DISPLAY_NAME}》，请欣赏。"
  if [[ "$has_speaker" == 1 ]]; then
    if [[ "$dry_run" == 1 ]]; then
      say "开场白｜${opening_text}｜等待 6 秒"
      dry_total=$((dry_total + 6))
    else
      say "开场白播报中……"
      # 多房间时对每台音箱依次下发同一文本
      for sdid in ${speaker_dids[@]+"${speaker_dids[@]}"}; do
        speak_text "$sdid" "$opening_text" || true
      done
      log "开场白播报：${opening_text}（等待 6 秒）"
      interruptible_sleep 6
    fi
  fi
  for (( idx = 0; idx < total; idx++ )); do
    CURRENT_SCENE=$((idx + 1))
    text="${SCENE_TEXTS[$idx]}"
    main="${SCENE_MAINS[$idx]}"
    wait_s="$(scene_wait_seconds "$text" "$has_speaker")"
    printf '%s\t%s\t%s\t%s\n' "$show_name" "$SHOW_DISPLAY_NAME" "$CURRENT_SCENE" "$total" >"$STATUS_FILE"

    if [[ "$dry_run" == 1 ]]; then
      say "第 ${CURRENT_SCENE}/${total} 景｜色对 ${main}｜估算 ${wait_s} 秒"
      say "  播报：${text}"
      dry_total=$((dry_total + wait_s))
      interruptible_sleep "$DRY_RUN_STEP_SECONDS"
      continue
    fi

    say "第 ${CURRENT_SCENE}/${total} 景开始"
    log "第 ${CURRENT_SCENE}/${total} 景：色对 ${main}，等待 ${wait_s} 秒"
    # 产品方裁决：同一房间所有淡彩光必须同一色对，且并发下发让多灯几乎同时变化
    # （串行逐台会造成相邻灯约 2 秒错峰）。每盏灯在各自后台作业里完成
    # 一次原子下发（色点 4.93/4.94 + 档位 4.106，必要时并入 4.37=2）；
    # 单灯失败只记该灯日志，不拖垮整景。日志顺序允许交错，每行自带 did 可辨。
    local i scene_jobs=()
    for (( i = 0; i < ${#lights[@]}; i++ )); do
      apply_light_color "${lights[$i]}" "$main" &
      scene_jobs+=("$!")
    done
    for i in ${scene_jobs[@]+"${scene_jobs[@]}"}; do
      wait "$i" 2>/dev/null || true
    done
    if [[ "$has_speaker" == 1 ]]; then
      for sdid in ${speaker_dids[@]+"${speaker_dids[@]}"}; do
        speak_text "$sdid" "$text" || true
      done
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
  local show_name="$1" want_room="${2:-}" want_lamp="${3:-}" show_file discovery filtered
  guard_duplicate
  if ! show_file="$(find_show_file "$show_name")"; then
    say "找不到名为「$show_name」的秀"
    list_shows || true
    exit 1
  fi
  load_show "$show_file" || exit 1
  # --lamp 前台预检：名称歧义或找不到必须当场报错（退出码 1），不能等后台进程才发现
  if [[ -n "$want_lamp" ]]; then
    if ! discovery="$(discover_lights)" || [[ -z "$discovery" ]]; then
      say "没有发现在线的馨光灯，请确认灯已通电在线后再播放"
      exit 1
    fi
    filtered="$(filter_lights_by_rooms "$discovery" "$want_room")"
    resolve_lamp_selection "$want_lamp" "$filtered" "$want_room" || exit 1
  fi
  XINGUANG_SHOW_ROOM="$want_room" XINGUANG_SHOW_LAMP="$want_lamp" nohup "${BASH_SOURCE[0]}" --player "$show_name" >>"$LOG_FILE" 2>&1 &
  disown 2>/dev/null || true
  say "已开始播放《${SHOW_DISPLAY_NAME}》，共 ${#SCENE_TEXTS[@]} 景"
  say "查看进度：xinguang-show --status；停止：xinguang-show --stop"
}

# 把校验通过的 .show（含 /tmp 草稿）保存为自定义秀；任何一景不过即拒存
cmd_save() {
  local src="$1" new_name="$2" src_file target
  new_name="${new_name%.show}"
  if [[ -z "$new_name" || "$new_name" == */* || "$new_name" == *..* || "$new_name" == .* || "$new_name" == -* ]]; then
    say "新秀名不合法：不能为空，不能包含路径分隔符，不能以点或横线开头"
    exit 1
  fi

  if [[ -f "$src" ]]; then
    src_file="$src"
  elif src_file="$(find_show_file "${src%.show}")"; then
    :
  else
    say "找不到要保存的秀：$src（可以给 .show 文件路径，也可以给已有秀名）"
    exit 1
  fi

  if ! load_show "$src_file"; then
    say "校验未通过，已拒绝保存；请按上面的提示修正后重试"
    exit 1
  fi
  if (( SHOW_SKIPPED_TOTAL > 0 )); then
    say "校验未通过：有 ${SHOW_SKIPPED_TOTAL} 景被跳过或拒播，已拒绝保存；请按上面的提示修正后重试"
    exit 1
  fi

  mkdir -p "$CUSTOM_SHOW_DIR"
  target="$CUSTOM_SHOW_DIR/$new_name.show"
  cp "$src_file" "$target"
  log "已保存自定义秀《${SHOW_DISPLAY_NAME}》为 $new_name（共 ${#SCENE_TEXTS[@]} 景）"
  say "已保存，下次说播放《${new_name}》即可"
}

usage() {
  cat <<'EOF'
用法：
  xinguang-show                          列出可播放的场景秀（分「预置」「自定义」两组）
  xinguang-show <秀名>                   播放指定的秀（后台推进，可随时停止）
  xinguang-show --room <房间名> <秀名>   只用这些房间的灯和音箱播放（多房间用逗号分隔，
                                         如 --room 门市,二楼客厅；重复传 --room 也可以）
  xinguang-show --lamp <灯名或did> <秀名>  只用指定的灯播放（多盏用逗号分隔；名称互为包含即命中，
                                         多命中会列候选让你补全；与 --room 同给时取交集）
  xinguang-show --dry-run <秀名>         演练：只打印动作，不控制设备
  xinguang-show --save <路径或秀名> <新名>  校验通过后保存为自定义秀
  xinguang-show --status                 查看是否在播、播到第几景
  xinguang-show --stop                   停止播放，灯光停在当前景
EOF
}

main() {
  command -v python3 >/dev/null 2>&1 || { say "缺少 python3，无法运行演示引擎，请联系工作人员处理"; exit 1; }
  local dry_run=0 room="${XINGUANG_SHOW_ROOM:-}" lamp="${XINGUANG_SHOW_LAMP:-}" names=()
  while (( $# > 0 )); do
    case "$1" in
      --dry-run)
        dry_run=1
        shift
        ;;
      --room)
        [[ -n "${2:-}" ]] || { say "--room 后面需要房间名（多个用逗号分隔）"; exit 1; }
        # 多值：逗号分隔；重复传参累加
        room="${room:+$room,}$2"
        shift 2
        ;;
      --lamp)
        [[ -n "${2:-}" ]] || { say "--lamp 后面需要灯的名称或 did（多个用逗号分隔）"; exit 1; }
        lamp="${lamp:+$lamp,}$2"
        shift 2
        ;;
      --status)
        cmd_status
        return 0
        ;;
      --stop)
        cmd_stop
        return 0
        ;;
      --save)
        [[ -n "${2:-}" && -n "${3:-}" ]] || { usage; exit 1; }
        cmd_save "$2" "$3"
        return 0
        ;;
      --player)
        # 内部入口：cmd_play 派生的后台播放进程
        # （房间经 XINGUANG_SHOW_ROOM、指定灯经 XINGUANG_SHOW_LAMP 传入）
        [[ -n "${2:-}" ]] || exit 1
        run_playback "$2" 0 "$room" "$lamp"
        return 0
        ;;
      --help|-h)
        usage
        return 0
        ;;
      --*)
        usage
        exit 1
        ;;
      *)
        names+=("$1")
        shift
        ;;
    esac
  done

  if (( ${#names[@]} == 0 )); then
    if (( dry_run )); then
      usage
      exit 1
    fi
    list_shows
    return 0
  fi

  if (( dry_run )); then
    guard_duplicate
    run_playback "${names[0]}" 1 "$room" "$lamp"
  else
    cmd_play "${names[0]}" "$room" "$lamp"
  fi
}

main "$@"
