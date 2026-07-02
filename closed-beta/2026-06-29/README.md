# 馨光 AI 设计灯光封测版

此目录用于封测验证，不挂正式首页。

当前封测版本：

- 第一阶段入口：2026-06-25.46
- 第一阶段主脚本：2026-06-25.46
- 第二阶段入口：2026-06-26.18
- 第二阶段主脚本：2026-06-26.18
- Skill：4.0.1

终端安装命令：

```bash
curl -fsSL https://raw.githubusercontent.com/nijez/xingguang-ai-lighting-guide/main/closed-beta/2026-06-29/install-xinguang-ai-light.sh -o install-xinguang-ai-light-closed-beta.sh && bash install-xinguang-ai-light-closed-beta.sh
```

状态查询：

```bash
bash install-xinguang-ai-light-closed-beta.sh status
```

本封测版保留终端一键安装作为主流程，并额外落地一个本地维护入口：

```bash
xinguang
```

维护入口只用于安装后的系统、龙虾、灯光连接组件和馨光 Skill 安装器维护，不包含灯光使用流程。

`wainfort-ai-lighting-run-skill.txt` 是馨光 Skill 文件的备用下载源，仅供安装器在标准 `SKILL.md` 路径不可用时自动兜底使用，不是用户操作入口。
