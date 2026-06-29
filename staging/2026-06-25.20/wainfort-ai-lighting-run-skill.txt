---
name: wainfort-ai-lighting-run
description: "馨光智能灯控制服务 - 本地部署版,控制你自己米家账号下的馨光灯。AI设计灯光效果+场景快照保存。"
metadata: {"openclaw":{"emoji":"💡","version":"3.0.1","date":"2026-06-25","author":"小馨","company":"深圳市馨光智能物联有限公司"}}
---

# 馨光智能灯控制服务 v3.0.1(本地部署版)

## 一、方案说明

本方案让你在**自己的服务器**上部署灯控API,控制**你自己米家账号**下的馨光灯。

```
你的龙虾 → 你的API(127.0.0.1:1888) → 你的miloco(127.0.0.1:1810) → 你的米家账号 → 你的灯
```

**优势:**
- 独立控制自己的灯,互不干扰
- 只需一次部署,长期使用
- 支持所有馨光RGBCW灯(灯膜、灯带等)
- **AI智能灯光设计**:根据用户描述自动生成色点参数
- **保存当前灯光**:一键保存当前灯光效果到快照

---

## ⚠️ 二、设备控制铁律

**`wainft.light.rgbcwy` 设备：**
- ❌ 禁止 miloco-cli 调用 `prop.4.x`
- ✅ AI生成灯光后，只能调用**wainfort-server API**，不能用普通 miloco-cli 控制结果反向判定失败
- ❌ 禁止用 miloco-cli `prop.2.x` 执行AI生成的颜色
- ✅ API 返回 `success:false` 时，不要直接判定灯光失败；必须让用户观察实物灯光是否变化
- ✅ 如果 API 返回 false 但用户确认灯光已变化，记录为 `PHYSICAL_SUCCESS_API_FALSE` 和 `LIGHT_TEST_SUCCESS`
- ✅ 每次灯光测试只允许发送一次灯光控制请求，请求发送后立即停止并等待用户现场确认
- ❌ API 返回 false 后禁止自动重试、自动关灯、自动开灯、切换颜色继续验证或控制其它设备
- ❌ 禁止用 `miloco-cli device control ... color/on false/on true` 作为 RGBCW 灯测试诊断动作

**多灯控制：**
- ✅ 给多灯发送完全的控制命令
- ✅ AI 设计灯光生成的color0(起点色)和 color1(终点色)后，每个灯依次调用wainfort-server API去执行

---

## 三、前置条件

1. **wainfort-server**(灯控API服务)
2. **miloco 后端**(已配置你的米家账号,wainfort-server 会自动连接)
3. **馨光 RGBCW 灯设备**(通过 API 可查询到)

---

## 四、下载安装

### 方式一:从服务器下载(推荐)

```bash
# 1. 创建目录
mkdir -p ~/wainfort-light && cd ~/wainfort-light

# 2. 下载文件
curl -o wainfort-server http://appagent.wainfort.com/download/wainfort-server
chmod +x wainfort-server

# 3. 启动服务
./wainfort-server
```

---

## 五、启动服务

```bash
cd ~/wainfort-light

# 前台运行
./wainfort-server

# 后台运行
nohup ./wainfort-server > api.log 2>&1 &
```

### 环境变量配置

| 变量 | 默认值 | 说明 |
|------|--------|------|
| WAINFORT_API_TOKEN | wainfort-ai-2026-*** | API认证Token |
| WAINFORT_MILOCO_URL | http://127.0.0.1:1810 | miloco后端地址 |
| WAINFORT_MILOCO_TOKEN | (空) | miloco认证Token(如果需要) |
| WAINFORT_API_PORT | 1888 | API监听端口 |

---

## 六、核心功能

### 功能一:AI 设计灯光

#### 触发条件

当用户说出以下类别的需求时,进入灯光设计流程:

**场景类:**
- "生成一个 XX 场景"(如:生日月光场景、九寨沟九月、春天色彩等)
- "设计一个 XX 灯光效果"
- "设置 XX 氛围的灯光"

**图片类:**
- "根据图片设置灯光"(用户上传图片)
- "让灯光匹配这张图的颜色"
- "参考这张图设计灯光"

**情绪/主题类:**
- "想要一个温馨/浪漫/科技感的灯光"
- "设计一个适合看电影/聚会/工作的灯光"

**自然色彩类:**
- "用自然风景的色彩设计灯光"
- "生成健康淡彩光效果"

#### 设计流程

```
Step 1: 理解用户需求 → 确定场景主题和色彩方向
Step 2: 生成两个色点 → color0(起点色)和 color1(终点色)
Step 3: 确定亮度 → 默认100,可根据需求调整
Step 4: 进入单次测试模式,记录 LIGHT_TEST_SINGLE_SHOT
Step 5: 只调用一次 API 执行灯光效果,记录 LIGHT_REQUEST_SENT
Step 6: 请求发送后立即停止,询问用户现场观察结果
```

#### 验收判断

灯光测试分三层判断：

1. 调用层：是否找到目标设备、是否调用 wainfort-server API、是否发送灯光请求。
2. 现场层：用户是否观察到灯光变化，灯光是否符合预期方向。
3. 返回层：API 返回 `success:true/false` 只作为参考，不作为 RGBCW 灯最终失败依据。

状态记录规则：

```text
LIGHT_REQUEST_SENT
LIGHT_API_RETURNED_FALSE
WAITING_PHYSICAL_CONFIRMATION
PHYSICAL_CHANGED
PHYSICAL_NOT_CHANGED
PHYSICAL_CONFIRMATION_REQUIRED
PHYSICAL_SUCCESS_API_FALSE
UNSTABLE_MULTIPLE_COMMANDS
LIGHT_TEST_SUCCESS
LIGHT_TEST_FAILED
```

执行灯光测试后必须回复：

```text
灯光请求已发送，请观察目标设备是否发生变化。
如果灯光已变化，请回复“已变化”。
如果没有变化，请回复“未变化”。
```

如果用户回复“已变化”，记录 `LIGHT_TEST_SUCCESS`。如果 API 返回 `success:false` 但用户回复“已变化”，同时记录 `PHYSICAL_SUCCESS_API_FALSE`，并说明“实际控制成功，API 返回状态需修复”。

如果现场出现连续变色、关灯再亮、或多个效果叠加，应记录 `UNSTABLE_MULTIPLE_COMMANDS`。这表示控制链路已触达设备，但本轮测试不是稳定验收；下一轮必须改为单次请求测试。

#### 单次测试禁止动作

对 RGBCW 灯光测试，以下动作禁止执行：

```text
miloco-cli device control ... color
miloco-cli device control ... on false
miloco-cli device control ... on true
重复调用 /api/generate
用其他设备做对照控制
API 返回 false 后自动重试
API 返回 false 后自动关灯再开灯
API 返回 false 后自动切换颜色继续验证
```

允许执行的只读检查：

```text
/api/status
/api/devices
设备列表查询
Skill 是否安装
服务是否运行
```

#### 色点生成规则

**色点格式**:`#RRGGBB`(16进制RGB值)

**⚠️ 重要规则:color0 和 color1 必须不同!**
- `color0` = 渐变起点色(灯带一端的颜色)
- `color1` = 渐变终点色(灯带另一端的颜色)
- 两个颜色形成渐变过渡效果,相同则无渐变
- 底层算法会自动处理白光融合,AI 无需考虑

**常用场景色点参考:**

| 场景 | color0 | color1 | 效果描述 |
|------|--------|--------|----------|
| 红苹果 | #DC2626 | #FF6B6B | 深红→浅红,温暖果实感 |
| 马尔代夫海 | #00B4D8 | #FFD166 | 海蓝→金黄,热带日落 |
| 武大樱花 | #FFB7C5 | #FFF5E6 | 粉色→奶白,春日浪漫 |
| 哆啦A梦 | #0095D9 | #FFFFFF | 蓝色→纯白,卡通梦幻 |
| 多巴胺治愈 | #FF9A76 | #FFEAA7 | 橙色→浅黄,温暖治愈 |
| 森林晨光 | #42802B | #91D099 | 深绿→浅绿,自然清新 |
| 日出朝霞 | #F3541C | #F1AB27 | 橙红→金黄,晨曦温暖 |
| 深海珍珠 | #2D63AD | #05A99E | 深蓝→青绿,深邃神秘 |
| 极光之夜 | #A1B1C8 | #C8C2CC | 银灰→淡紫,科幻冷调 |
| 金色年华 | #556A95 | #FFC044 | 灰蓝→金黄,高级质感 |
| 秋日枫叶 | #A8EFFE | #F25431 | 浅蓝→枫红,秋意浪漫 |
| 冰川幽蓝 | #88B2ED | #D9F3FD | 浅蓝→冰白,清爽冷静 |
| 萤火虫夜 | #95FF89 | #EDF468 | 荧光绿→嫩黄,梦幻夜景 |
| 玫瑰花语 | #EF6A85 | #FFC6C5 | 玫瑰粉→浅粉,浪漫柔情 |

#### API 调用

```bash
curl -X POST http://127.0.0.1:1888/api/generate \
  -H "Authorization: Bearer wainfort-ai-2026-你的本地Token" \
  -H "Content-Type: application/json" \
  -d '{
    "did": "设备DID",
    "color0": "#起点色RRGGBB",
    "color1": "#终点色RRGGBB",
    "brightness": 100
  }'
```

**注意:** color0 和 color1 是灯带两端的颜色,必须不同才能形成渐变效果。API 返回 `success:false` 时仍要询问用户观察结果，不要自动重试，不要自动关灯或切换颜色，不要用 miloco-cli 直接控制结果反向判定 RGBCW 灯失败。

---

### 功能二:保存场景快照

#### 触发条件

当用户说出以下需求时,进入保存快照流程:

**保存类:**
- "保存当前的灯光效果"
- "保存当前场景"
- "保存快照"
- "记住这个灯光设置"
- "把这个效果存起来"

#### 保存流程

```
Step 1: 确认用户要保存当前灯光效果
Step 2: 询问保存位置(快照1-6)
Step 3: 调用保存API
Step 4: 返回保存结果
```

#### 快照编号规则

| 快照ID | 编号 | 说明 |
|--------|------|------|
| 1 | 83886335 | 快照1 |
| 2 | 83951871 | 快照2 |
| 3 | 84017407 | 快照3 |
| 4 | 84082943 | 快照4 |
| 5 | 84148479 | 快照5 |
| 6 | 84214015 | 快照6 |

#### API 调用

```bash
curl -X POST http://127.0.0.1:1888/api/save-scene \
  -H "Authorization: Bearer wainfort-ai-2026-你的本地Token" \
  -H "Content-Type: application/json" \
  -d '{
    "did": "设备DID",
    "snapshot_id": 5
  }'
```

**快照范围:** 1-6

---

## 七、查询功能

### 1. 查询状态

```bash
curl http://127.0.0.1:1888/api/status
```

### 2. 查询设备

```bash
curl http://127.0.0.1:1888/api/devices \
  -H "Authorization: Bearer wainfort-ai-2026-你的本地Token"
```

找到 `model=wainft.light.rgbcwy` 的设备,其 `did` 就是你要控制的设备。

---

## 八、完整执行流程示例

### 示例1：用户说“设计一个温馨的生日灯光”

```
1. AI 理解需求 → 温馨、生日、暖色调
2. 生成色点：
   - color0: #FF9A76（温暖橙色）
   - color1: #FFEAA7（柔和黄色）
3. 直接调用 API 执行
4. 记录 LIGHT_REQUEST_SENT
5. 提示用户观察灯光是否变化
6. 根据用户反馈记录 LIGHT_TEST_SUCCESS 或 LIGHT_TEST_FAILED
```

### 示例2:用户说"保存当前灯光到快照3"

```
1. AI 理解需求 → 保存当前效果
2. 确认快照位置:快照3
3. 调用保存API
4. 返回保存结果
```

---

## 九、故障排查

### API无法启动
- 检查端口是否被占用:`ss -tlnp | grep 1888`
- 检查文件权限:`chmod +x wainfort-server`

### 灯控命令失败
- 检查miloco后端是否运行:`curl http://127.0.0.1:1810/`
- 检查设备DID是否正确:通过API `/devices` 查询
- 检查设备是否在线

### 保存快照失败
- 确认设备支持场景快照功能
- 快照ID必须在1-6范围内

---

## 十、技术支持

- 公司:深圳市馨光智能物联有限公司
- 网址:www.wainfort.com
- 电话:0755-26400977
