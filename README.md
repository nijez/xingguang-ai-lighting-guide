# 馨光 AI 设计灯光安装指导

这是给腾讯云 / 阿里云 OpenClaw 应用模板使用的一键部署教程和脚本。

- 图文教程：https://nijez.github.io/xingguang-ai-lighting-guide/
- 一键脚本：https://nijez.github.io/xingguang-ai-lighting-guide/install-miloco-openclaw-cloud.sh
- 备用脚本：https://raw.githubusercontent.com/nijez/xingguang-ai-lighting-guide/main/install-miloco-openclaw-cloud.sh
- CDN 备用脚本：https://cdn.jsdelivr.net/gh/nijez/xingguang-ai-lighting-guide@main/install-miloco-openclaw-cloud.sh
- 查看进度指令：https://nijez.github.io/xingguang-ai-lighting-guide/%E6%9F%A5%E7%9C%8B%E5%AE%89%E8%A3%85%E8%BF%9B%E5%BA%A6%E7%9A%84%E6%8C%87%E4%BB%A4.txt

最简单用法：

1. 云服务器创建时选择 OpenClaw 应用模板。
2. 打开 OpenClaw 对话框。
3. 复制教程页面里的“一键部署指令”发给 OpenClaw。
4. OpenClaw 会启动后台安装进程，并每 20 秒按日志汇报进度。
5. 如果日志 180 秒没有变化，它会主动报告进程仍在运行但暂无新日志。
6. 如果对话窗口中断，复制“查看安装进度指令”给 OpenClaw。

脚本版本：2026-06-24.1。脚本默认不会保存 SSH 密码、token、MiMo API Key，也默认跳过微信、米家账号和 MiMo Key 绑定。
