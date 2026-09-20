# Ark × Hermes 本地 Agent

2026-09-20：Ark 主对话和语音任务已可发现、读取并执行 Hermes 技能工作流。Hermes CLI 到 Ark 原生动作的既有桥接继续可用。

## 使用

本项目已存在的 `.hermes-lab` 配置可直接使用。首次准备或迁移到另一台机器，在已有 Hermes lab 基础上运行：

```bash
backend/.venv/bin/python scripts/setup_hermes_runtime.py
./scripts/run_backend.sh
./scripts/build_app.sh
open "build/Ark Intelligence.app"
```

安装脚本将参数校验、Word、Excel、PDF、PPT、数据分析依赖安装到 Hermes 独立 venv，将固定版本 agent-browser 安装到 lab home；不升级 Hermes/OMH，不修改全局 npm。浏览器配置为本地模式，使用已安装的 Google Chrome 和独立自动化会话。没有 Chrome 时需要安装 Chromium，并配置 `AGENT_BROWSER_EXECUTABLE_PATH`。`--without-browser` 可跳过浏览器安装。

在 Skill 管理中可以搜索 Hermes 工作流并单独启停；“Hermes 本地能力”控制整体接入。示例请求：

- “查找并读取 Hermes 的 docx 技能，告诉我有哪些脚本。”
- “用 Word 技能在指定路径生成一份项目周报，然后检查文件。”
- “打开这个网页并提取表格。”

每个 Hermes 工具执行都会在现有任务栏显示工具名、完整参数、工作目录和权限范围，等待用户确认。读取技能目录、指导和附件不需要执行审批。等待审批时尚未执行。

## 集成结构

- Ark 保留 Sophie 身份、本地 Ollama 推理、长期记忆、语音、会话、审批和任务事件流。
- `skills/hermes` 注册 4 个模型入口：`hermes.skills_list`、`hermes.skill_view`、`hermes.tools_list`、`hermes.execute`。模型先搜索技能、读取指导与附件，再查询工具参数并执行。
- `backend/tools/hermes.py` 使用 Hermes venv 启动独立 worker，避免双方的 `agent` / `tools` Python 包冲突。每个 Ark 任务独立进程；同一任务内保留浏览器、文件读写追踪和终端状态，结束或取消后清理。浏览器会话不跨任务延续。
- `integrations/hermes/worker.py` 调用 Hermes 自己的技能发现与加载器，继承平台过滤、禁用列表、外部目录和插件技能；不复制技能，不执行读取指导中的内嵌 shell 模板。返回真实 `skill_dir` 和 `runtime_python`，附件和长文本支持分页。
- 工具使用 Hermes 当前定义与依赖检查。审批前校验参数，审批后重查启用状态和 schema 摘要；拒绝、取消和失败均进入 Ark 日志。桥接令牌无权调用反向适配器，避免递归执行与审批绕过。
- 原生图像结果会把实际像素交给 Ark 当前本地模型分析，不将 base64 塞入文本对话或任务日志。需要模型支持视觉；不增加云端推理回退。

本机本轮发现 **186 个技能、16 个运行时工具**：文件读取、写入、补丁、搜索、终端、10 个浏览器动作和图像分析。数字取决于 Hermes 配置和依赖。`GET /agent/capabilities`（Ark 客户端令牌）返回当前模型、原生动作、Hermes 数量、工具名、工作目录和连接错误。

## 配置和边界

默认自动识别项目内 `.hermes-lab`。可在启动后端前设置：

| 变量 | 用途 |
| --- | --- |
| `ARK_HERMES_HOME` | 已配置的 Hermes home，含 config.yaml 与 skills |
| `ARK_HERMES_PYTHON` | 装有 Hermes 和 requirements-ark.txt 的 Python 可执行文件 |
| `ARK_HERMES_WORKSPACE` | 已存在的默认工具工作目录 |
| `AGENT_BROWSER_EXECUTABLE_PATH` | 可选的本地 Chrome/Chromium 可执行文件 |

本适配器要求 Hermes `terminal.backend: local`；远程/容器后端不在此次支持范围内。终端默认目录绑定到上述工作目录，工具显式 `workdir` 会显示在预览里。

Hermes 执行与 `ark.workspace` 的能力范围不同：Hermes 使用本机账户权限并可联网，所有实际工具调用均需审批；Ark workspace 继续执行原有专用目录、沙箱和禁网络策略。前台终端限 60 秒，不支持后台、PTY 或交互命令。超时、断线和取消后可能已有部分副作用，不能自动重试未知结果的操作。确认产物需读回验证。

技能被发现不代表它的所有服务已配置。常用 Office/PDF Python 依赖已补齐；其他技能仍可能需要外部账号、API key、命令或大型软件。加载时报告 Hermes 原有 readiness，以及常用 Office 技能缺失的 Python 模块。没有开放 Hermes 的嵌套 agent、凭证管理、cron、技能修改、独立记忆工具；Ark 继续提供统一的记忆与任务入口，日历/提醒/应用操作优先使用 Ark 原生动作。OMH 技能目录可被发现，OMH 的独立记忆数据库没有合并进 Ark。

目录缓存 30 秒；新增或删除技能后稍候刷新。Ark 的单技能开关独立保存，不修改 Hermes CLI 配置；Hermes 已禁用的技能不会被 Ark 重新启用。没有 Hermes 环境时显示不可用原因，Ark 原有工具继续可用。

## 验证

```bash
PYTHONPATH=backend ARK_TEST_HERMES=1 ARK_TEST_SANDBOX=1 \
  backend/.venv/bin/python -m unittest discover -s backend/tests -v
swift test --package-path frontend --scratch-path /private/tmp/ark-hermes-swift-tests -j 2
PYTHONPATH=backend backend/.venv/bin/python scripts/hermes_runtime_smoke_test.py --model --browser --vision
```

测试脚本使用临时任务数据库和临时文件。只自动批准脚本中固定的测试命令与导航参数，不能用于自动批准真实用户任务。

本轮已通过：本地 Qwen 自主搜索与读取 docx 技能；真实技能指导与附件读取和路径越界拒绝；审批后运行 docx 脚本生成 Word 文件并验证包内容；本地 Chrome 打开 example.com 并返回页面快照；Hermes 加载纯色测试图、实际像素传给本地 Qwen 并正确识别颜色；禁用、拒绝、参数错误、执行失败、取消、超时清理及桥接令牌边界。后端 53 项与 Swift 10 项测试通过，应用构建签名完成，界面搜索 docx/OMH 技能已验收。复杂视觉质量和全部 186 个技能尚未逐一验收。语音和长期记忆沿用原系统，本轮没有重新评测听感或长期召回质量。

本机日志保存在 `.hermes-lab/reports/ark-integration-*`，不提交临时文件、令牌或个人数据。
