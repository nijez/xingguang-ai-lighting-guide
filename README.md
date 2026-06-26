# 馨光 AI 设计灯光安装指导

准备好腾讯云轻量服务器的小龙虾（OpenClaw）应用模板和 MiMo API Key 后，把固定安装指令发给小龙虾对话页即可开始安装。

`2026-06-25.4` 为今晚内测发布版本，包含阶段性进度播报和安装完成后的下一步引导。

## 项目目标

完成安装后，用户可以在小龙虾里输入灯光需求，例如：

```text
吊顶灯带，设计个马尔代夫灯光效果。
```

小龙虾会通过馨光 Skill 控制馨光设备，生成对应的 AI 设计灯光效果。

## 4 大步骤

1. 准备小龙虾服务器：购买腾讯云轻量服务器，并选择小龙虾应用模板。
2. 配置小龙虾：开通小米 MiMo 大模型账号，获取并填写 MiMo API Key，绑定微信小龙虾。
3. 安装馨光 AI 设计灯光：把固定安装指令发给小龙虾对话页。
4. 配置并测试灯光效果：配置灯光能力 MiMo API Key，绑定米家账号，安装馨光 Skill；如果有多个米家家庭，选择馨光设备所在家庭，之后直接用自然语言控制灯光。

## 教程页面

- 本地教程：[docs/miloco-openclaw-cloud-install.html](docs/miloco-openclaw-cloud-install.html)
- 公开地址：https://nijez.github.io/xingguang-ai-lighting-guide/

## 相关入口

- 购买腾讯云小龙虾服务器：https://cloud.tencent.com/act/pro/openclaw
- 查看腾讯云 OpenClaw 实践教程：https://cloud.tencent.com/document/product/1207/127874
- 小米 MiMo 订阅管理 / 获取 API Key：https://platform.xiaomimimo.com/console/plan-manage

## MiMo API Key 说明

小龙虾和馨光 AI 设计灯光能力都会用到 MiMo API Key。

- 小龙虾 MiMo API Key：用于小龙虾正常对话和执行任务。
- 灯光能力 MiMo API Key：用于馨光 AI 设计灯光能力。
- 这两个位置可以使用同一个 MiMo API Key。

安装过程中不会要求填写你的 API Key。安装完成后，再按页面提示完成 MiMo API Key、米家账号和米家家庭选择。

## 测试灯光示例

```text
客厅设计一个马尔代夫灯光效果。
二楼客厅来一个森林晨光。
卧室做一个适合睡前放松的灯光。
全屋灯带做一个朋友聚会氛围。
保存当前灯光效果到快照 3。
```

## 异常处理

如果安装过程中页面短暂异常，通常是小龙虾后台服务正在重启。

请等待 1-3 分钟后刷新页面。刷新后如果是空白对话框，直接发送「查看安装进度」。

不要重复发送一键部署指令。

如果多次刷新后仍无法查看进度，请联系技术人员处理。

## 当前说明

完成前面步骤后，可以继续安装馨光 Skill。安装完成后，如果你的米家账号下有多个家庭，请选择馨光设备所在的家庭。之后你可以直接告诉小龙虾想要的灯光效果，例如“客厅设计一个马尔代夫灯光效果”，小龙虾会通过馨光 Skill 控制馨光设备。
