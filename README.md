# 馨光 AI 设计灯光安装指导

这个目录里的脚本用于「馨光 AI 设计灯光」第一阶段交付：在腾讯云轻量应用服务器的 OpenClaw 应用模板上部署 OpenClaw + Miloco 2.0 底座。默认不绑定微信、不绑定米家账号、不写入 MiMo API Key，也不会声称已经完成馨光智能 Skill。

`2026-06-25.3` 已完成真实腾讯云 OpenClaw 应用模板服务器验证，第一阶段底座部署版本已冻结。

## 快速用法

图文版教程页面：

- [docs/miloco-openclaw-cloud-install.html](docs/miloco-openclaw-cloud-install.html)
- 公开教程地址：https://nijez.github.io/xingguang-ai-lighting-guide/
- 公开脚本地址：https://nijez.github.io/xingguang-ai-lighting-guide/install-miloco-openclaw-cloud.sh
- 公开脚本备用地址：https://raw.githubusercontent.com/nijez/xingguang-ai-lighting-guide/main/install-miloco-openclaw-cloud.sh
- 公开脚本 CDN 备用地址：https://cdn.jsdelivr.net/gh/nijez/xingguang-ai-lighting-guide@main/install-miloco-openclaw-cloud.sh

默认使用 OpenClaw / AgentChat / 龙虾对话框执行安装，不要求普通用户填写服务器 IP。SSH 只作为高级维护和故障排查附录。

如果使用腾讯云 OpenClaw 应用模板，可以直接把 `docs/发给龙虾的部署指令.txt` 里的内容发给 OpenClaw。它会从公开固定地址下载安装脚本并执行。

OpenClaw 对话模式使用“前台启动 + 后台 supervisor 部署”：

- 安装进程写入 `/tmp/openclaw-miloco-install-current.log`。
- 进程号写入 `/tmp/openclaw-miloco-install.pid`。
- 状态写入 `/tmp/openclaw-miloco-install.state`。
- 一键部署指令只负责启动独立后台任务，并尽快结束当前回复。
- 后台任务负责 OpenClaw 最低版本检查、必要时升级、Miloco 2.0 部署和 Gateway 重启。
- 如果 Gateway 重启导致 AgentChat 页面短暂断线，等待 1-3 分钟后刷新页面；如果刷新后是空白对话框，直接发送 `docs/查看安装进度的指令.txt`。

## EdgeOne 发布状态

已整理可直接上传 EdgeOne Makers 的静态站点目录：

- `edgeone-site/index.html`
- `edgeone-site/install-miloco-openclaw-cloud.sh`
- `edgeone-site/发给龙虾的部署指令.txt`
- `edgeone-site/馨光 AI 设计灯光安装指导.zip`

国内/全球含大陆区域的 EdgeOne Makers 项目域名和部署域名只适合临时预览。当前长期公开给别人访问的版本以 GitHub Pages 为准。

当前国内项目：

- 项目名：`xingguang-ai-lighting-guide`
- 项目 ID：`makers-wktoz5rg8fre`
- 项目域名：`xingguang-ai-lighting-guide-kj7bxxhr.edgeone.cool`

高级维护场景下，才需要把脚本传到服务器后执行：

```bash
scp scripts/install-miloco-openclaw-cloud.sh ubuntu@服务器IP:/tmp/
ssh ubuntu@服务器IP
bash /tmp/install-miloco-openclaw-cloud.sh
```

人工运行时会进入纯终端菜单：

```text
请选择操作:
  1) 一键傻瓜式部署
  2) 功能模块维护
  3) 平台绑定
  4) 查看服务状态
  5) 查看安装日志
  0) 退出
```

菜单含义：

- `1`：一键傻瓜式部署，按顺序完成依赖检查、OpenClaw 状态检查、Miloco 2.0 部署，并提示是否做平台绑定和米家绑定。
- `2`：进入功能模块维护子菜单，针对 OpenClaw、Miloco、服务重启等单项维护，不会从头重复完整部署。
- `3`：进入平台绑定子菜单，包含个人微信、企业微信、飞书。
- `4`：查看 OpenClaw / Miloco / 插件状态。
- `5`：查看当前安装日志。

功能模块维护子菜单：

```text
功能模块维护:
  1) OpenClaw 升级 / 网关配置
  2) Miloco 2.0 安装 / 更新
  3) 核心模块更新 / 修复
  4) 重启 OpenClaw gateway
  5) 重启 Miloco service
  6) 查看模块状态
  0) 返回上级菜单
```

一键傻瓜式部署会显示 6 步：

```text
Step 1/6: Base packages check
Step 2/6: OpenClaw check and gateway config
Step 3/6: Install and deploy Miloco 2.0
Step 4/6: Ask OpenClaw platform binding
Step 5/6: Prompt Miloco Mi Home account binding
Step 6/6: Verify services and print next manual actions
```

如果要无人值守完整部署，用：

```bash
INSTALL_ACTION=full RUN_SYSTEM_UPGRADE=0 OPENCLAW_UPDATE=auto INSTALL_EXTRA_PLUGINS=0 INSTALL_NONINTERACTIVE=1 bash /tmp/install-miloco-openclaw-cloud.sh
```

## 常用参数

继续未完成部署：

```bash
INSTALL_ACTION=continue RUN_SYSTEM_UPGRADE=0 OPENCLAW_UPDATE=auto INSTALL_EXTRA_PLUGINS=0 bash /tmp/install-miloco-openclaw-cloud.sh
```

高级维护升级：

```bash
INSTALL_ACTION=full RUN_SYSTEM_UPGRADE=1 OPENCLAW_UPDATE=1 INSTALL_EXTRA_PLUGINS=1 bash /tmp/install-miloco-openclaw-cloud.sh
```

安装时顺便写入 MiMo Key：

```bash
INSTALL_ACTION=miloco MIMO_API_KEY='sk-xxx' bash /tmp/install-miloco-openclaw-cloud.sh
```

使用指定 Miloco 版本：

```bash
INSTALL_ACTION=miloco MILOCO_VERSION=2026.6.18 bash /tmp/install-miloco-openclaw-cloud.sh
```

网关绑定到内网而不是本机回环地址：

```bash
INSTALL_ACTION=openclaw OPENCLAW_BIND=lan bash /tmp/install-miloco-openclaw-cloud.sh
```

只有自己明确知道安全边界时才建议这么做。默认 loopback 更安全。

## 下载源策略

脚本默认不要求你提供自己的服务器、COS 或 OSS。它会直接尝试：

1. Miloco 官方 GitHub release。
2. Miloco 官方 manifest 里带的公开 GitHub 代理源。
3. 额外公开 GitHub release 代理源，例如 `ghfast.top`、`ghproxy.net`。
4. OpenClaw 官方安装入口仅在 OpenClaw 不存在、已安装版本低于 `OPENCLAW_MIN_VERSION`，或明确传入 `OPENCLAW_UPDATE=1` 时使用。
5. npm 默认自动测速：npmmirror、官方 npm、腾讯云、华为云，选当前响应最快的；OpenClaw 安装失败时再回退官方 npm registry。
6. PyPI 默认自动测速：清华 TUNA、中科大、官方 PyPI，选当前响应最快且兼容 Miloco 依赖时间约束的源。
7. 如果 PyPI 镜像解析失败，自动回退官方 PyPI。

通常直接跑就行：

```bash
bash /tmp/install-miloco-openclaw-cloud.sh
```

如果是自动化快照验证，使用轻量完整部署动作，并关闭人工绑定提问：

```bash
INSTALL_ACTION=full RUN_SYSTEM_UPGRADE=0 OPENCLAW_UPDATE=auto INSTALL_EXTRA_PLUGINS=0 INSTALL_NONINTERACTIVE=1 bash /tmp/install-miloco-openclaw-cloud.sh
```

测速是默认开启的。想关闭自动测速，按固定顺序尝试下载源：

```bash
AUTO_SELECT_MIRRORS=0 bash /tmp/install-miloco-openclaw-cloud.sh
```

想固定使用某个 PyPI 镜像，可以指定：

```bash
PYPI_INDEX=tuna bash /tmp/install-miloco-openclaw-cloud.sh
```

可选值：

- `auto`：自动测速选择，默认值。
- `official`：官方 PyPI。
- `tuna`：清华 TUNA。
- `aliyun`：阿里云 PyPI。
- `tencent`：腾讯云 PyPI。
- `ustc`：中科大 PyPI。

如果国内 PyPI 解析失败，脚本默认会自动回退官方 PyPI。你也可以指定任意简单索引 URL：

```bash
PYPI_INDEX='https://pypi.tuna.tsinghua.edu.cn/simple' bash /tmp/install-miloco-openclaw-cloud.sh
```

npm 源默认也是自动测速，候选包括 npmmirror、官方 npm、腾讯云、华为云。想固定 npm 源：

```bash
NPM_REGISTRY='https://registry.npmmirror.com' bash /tmp/install-miloco-openclaw-cloud.sh
```

如果要完全走官方 npm，或者关闭 npm 源环境变量：

```bash
NPM_REGISTRY='https://registry.npmjs.org' bash /tmp/install-miloco-openclaw-cloud.sh
```

不建议默认使用 `PYPI_INDEX=aliyun`、`PYPI_INDEX=tencent`、`PYPI_INDEX=huawei`。2026-06-22 在腾讯云 Ubuntu 24.04 实测中，这几类镜像缺 upload date 元数据，会和 Miloco 安装器的 `exclude-newer` 约束冲突，导致依赖解析失败；清华 TUNA、中科大和官方 PyPI 可以通过这个约束。

如果安装中出现：

```text
ERROR: Failed to download Miloco installer
```

说明前置检查已完成，但服务器当前无法下载 Miloco 官方安装器。不要反复执行同一份旧脚本；先上传最新版脚本，然后用续跑模式继续：

```bash
scp scripts/install-miloco-openclaw-cloud.sh ubuntu@服务器IP:/tmp/
ssh ubuntu@服务器IP
INSTALL_ACTION=continue RUN_SYSTEM_UPGRADE=0 OPENCLAW_UPDATE=auto INSTALL_EXTRA_PLUGINS=0 bash /tmp/install-miloco-openclaw-cloud.sh
```

新版脚本启动时会显示脚本版本，例如：

```text
Starting Xingguang AI lighting install (script 2026-06-25.3)
```

脚本会按 6 个步骤显示进度：

```text
Step 1/6: Base packages check
✓ Step 1/6 done: Base packages check
...
Step 4/6: Ask OpenClaw platform binding
Step 5/6: Prompt Miloco Mi Home account binding
```

默认第 4 步会跳过微信。以后要安装并扫码登录微信插件，再运行：

```bash
INSTALL_ACTION=weixin RUN_SYSTEM_UPGRADE=0 bash /tmp/install-miloco-openclaw-cloud.sh
```

或者使用菜单：`3) 平台绑定` -> `1) 个人微信`。

同一版本 Miloco 的大包会缓存在 `~/.cache/miloco-cloud-installer/`。后续重复运行脚本时会校验 SHA 后复用缓存，减少反复下载。

下载 Miloco 时还会显示：

```text
Benchmarking Miloco installer sources
```

如果没有看到这两行，通常说明服务器上的 `/tmp/install-miloco-openclaw-cloud.sh` 还不是最新版。

默认部署不会做完整系统升级，也不会主动安装新内核。只有显式设置 `RUN_SYSTEM_UPGRADE=1` 时，脚本才可能提示建议重启；脚本不会自动重启，避免教程录制或截图过程中连接突然断开。

## 多轮快照验证

为了验证脚本在“刚重装完系统并设置好密码”的服务器上稳定可复现，可以使用本地测试执行器。每次先在云厂商控制台把服务器恢复到同一快照，然后运行：

```bash
SERVER_HOST=服务器IP RUN_LABEL=round1 scripts/run-remote-install-measure.sh
```

执行器会：

- 上传最新版安装脚本到 `/tmp/install-miloco-openclaw-cloud.sh`。
- 在服务器上完整运行安装。
- 保存服务器日志到 `/home/ubuntu/miloco-cloud-install-时间戳.log`。
- 保存本地终端日志到 `runs/install-tests/时间戳-round1.log`。
- 输出 `REMOTE_TOTAL_SECONDS`，用于比较每轮总耗时。

第 2、3 轮把 `RUN_LABEL` 改成 `round2`、`round3` 即可。不要把 SSH 密码写进脚本文件；执行器会在运行时提示输入密码。

`scripts/build-miloco-wheelhouse.sh` 仍然保留，但它只是兜底工具；你不需要自己的服务器就可以使用主安装脚本。

## 安装后操作

配置模型：

```bash
miloco-cli config set model.omni.api_key sk-xxx
```

绑定米家账号：

```bash
miloco-cli account bind
```

确认馨光淡彩光设备：

```bash
miloco-cli device list
```

访问 Miloco 面板需要先建立 SSH 隧道。`127.0.0.1:1810` 是云服务器内部地址，不能在自己电脑上直接打开：

```bash
ssh -L 1810:127.0.0.1:1810 ubuntu@服务器IP
```

然后打开：

```text
http://127.0.0.1:1810/
```

微信绑定暂时不做。以后要接微信时再单独运行 OpenClaw 的微信通道登录命令。
