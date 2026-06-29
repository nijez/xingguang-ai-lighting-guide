# 馨光 Doctor 与终端维护面板设计

更新时间：2026-06-29

## 目标

项目已经从“教程页 + 安装脚本”进入内测交付阶段。后续真实状态不能再依赖龙虾对话里的主观回复，必须由终端侧的 Doctor 和维护面板提供可复核的状态来源。

核心分工：

- 龙虾：面向内测用户，只负责下一步引导和极简反馈。
- Doctor：面向维护人员，负责真实状态检查和分层结论。
- 终端维护面板：面向维护人员，负责只读查看、明确确认后的修复动作、脱敏诊断导出。

## 统一状态文件

统一状态文件位于：

```text
~/xinguang-ai-light/state.json
```

状态文件 schema 为 `xinguang-state-v1`，由安装器、Doctor 和维护面板共同维护。状态文件只记录 token 是否存在、长度或 hash 前缀，不记录完整 token。

主要区块：

- `release`：第一阶段、第二阶段、Skill 版本。
- `openclaw`：CLI、gateway、连通性、lightclawbot 状态。
- `mijia`：米家绑定、当前家庭、目标家庭。
- `miloco`：授权信息是否存在、是否同步到灯光服务。
- `wainfort`：灯光服务、系统服务、接口、设备列表状态。
- `skill`：馨光 Skill 是否安装、版本是否匹配。
- `natural_language`：最近一次自然语言请求链路占位。

## xinguang-doctor

`xinguang-doctor` 默认只读，不执行修复动作。

检查范围：

1. 版本是否漂移。
2. OpenClaw CLI 和 gateway 是否一致。
3. gateway 是否 active running。
4. lightclawbot 是否连接。
5. 米家是否绑定。
6. 当前家庭和目标家庭是否明确。
7. Miloco 授权信息是否存在。
8. 授权信息是否同步到灯光服务。
9. 灯光服务是否 active running。
10. 灯光服务接口是否可访问。
11. 设备列表接口是否 200。
12. `devices=""` 是否被标记为 WARN。
13. 馨光 Skill 是否安装。
14. Skill 文件版本是否为 4.0.1。
15. 安装器里的 Skill 版本是否与 Skill 文件一致。

Doctor 的最终输出必须包含 L1-L6 分层结论。

## xinguang-panel

`xinguang-panel` 是终端维护入口，不放到普通用户页面的主流程里。

默认行为：

- 只读。
- 修改类动作必须二次确认。
- 不显示完整 token。
- 诊断包自动脱敏。

菜单：

1. 查看总体状态
2. 运行完整 Doctor
3. 查看版本信息
4. 查看 OpenClaw gateway 状态
5. 修复 OpenClaw gateway service
6. 查看米家绑定状态
7. 设置目标家庭
8. 同步 Miloco token 到灯光服务
9. 启动 / 重启灯光服务
10. 查看灯光服务状态
11. 查询设备列表
12. 执行本地测试场景
13. 查看 Skill 安装状态
14. 重新安装馨光 Skill
15. 导出脱敏诊断包
16. 退出

## root fallback systemd 约束

wainfort-server 当前版本存在固定目录写入行为。正式安装器不能把整个安装流程改成 root，也不能 patch 二进制。

当前策略：

- 优先用 ubuntu 用户启动。
- 如果检测到固定目录权限错误，才使用 root systemd 兜底。
- 仅 wainfort-server 服务使用 root。
- systemd env 显式写入 `WAINFORT_MILOCO_TOKEN` 和 `HOME=/home/ubuntu`。
- env 文件权限必须为 600。
- 服务必须配置 `Restart=always`。
- 启动后必须检查 `/api/status` 和 `/api/devices`。
- `/api/devices` 返回 200 但设备为空时，只能记为 WARN，不能当作设备发现成功。

## 用户侧降噪原则

普通用户看不到 token、端口、PID、日志路径、systemd、ExecStart、API、base64、内部路径和底层错误分析。

龙虾回复只保留：

- 收到。
- 下一步。
- 请联系工作人员处理。

真实诊断全部进入 Doctor、维护面板和脱敏诊断包。
