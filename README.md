# Ark Intelligence

面向 macOS 的本地 AI 助手：以 SwiftUI 原生界面连接本地模型，将文字对话、长期记忆、Sophie 中英文语音和需要用户审批的系统操作整合到同一套任务流程。

**开发状态：可运行的本地 Agent 开发版，持续迭代中。** 本文基于 2026-09-20 的代码与开发记录；功能已实现不等于已完成所有场景验收，目前尚非稳定发行版。

## 当前开发进度

| 模块 | 已实现 | 当前边界 |
| --- | --- | --- |
| macOS 客户端 | 原生聊天、历史、记忆管理、Skill 管理、独立任务侧栏；任务进度、审批与取消 | 最低目标 macOS 14；主要实机验证集中在开发机 |
| 本地 Agent | Ollama 工具调用循环、会话持久化、后台任务、事件续传；最多 4 个活动任务，主模型推理串行 | 默认 8K 上下文，云端模型关闭 |
| 长期记忆 | SQLite 存储、向量检索、显式记忆、会话结束整理和记忆生命周期管理 | 真实长期会话的召回质量仍需持续评估 |
| Skill 系统 | JSON Schema 清单校验、启停、统一调用协议、调用日志、审批摘要绑定、执行后核验 | 通用第三方插件隔离仍属后续范围 |
| 网络搜索 | 搜索与网页读取、来源链接、Bing RSS / DuckDuckGo 后备、内网地址拦截和响应体限制 | 需要联网，受搜索提供方可用性影响 |
| macOS 原生操作 | 应用查找/打开/切换/正常退出；日历与提醒事项查询和增删改，共 16 个动作 | 日历/提醒写操作需审批与系统权限；重复事项编辑和真实数据写入仍需专项验收 |
| 通知智能总结 | 手动 AX 采集、统一 Ark Event、本机去重保存、按时间及应用查询、本地模型摘要 | 默认关闭；只覆盖通知中心可读取内容及已保存记录，无法恢复全部历史；真实微信采集待实机验收，见 [使用与开发说明](docs/notification-awareness.md) |
| Sophie 语音 | Hey Sophie 唤醒、VAD、本地 ASR/TTS、字幕、连续会话、输入设备选择、明确唤醒打断、噪声过滤 | 真人听感、多口音、远场、回声、蓝牙长期稳定性和误唤醒率尚未全面验收 |
| 文件与终端 | 专用工作区列文件、读取、审批写入与版本冲突检查；审批后运行受限 shell | 新增能力；shell 依赖 macOS `sandbox-exec`，禁网络，最长 60 秒；不提供任意个人目录访问 |
| Hermes 集成 | 双向桥接；Ark 主对话可搜索、加载 Hermes 技能及附件，审批执行文件、终端、浏览器和视觉工具；本机发现 186 个技能 | 常用 Office/PDF 依赖已补齐；外部服务技能仍需账号和依赖，技能数不等于全部工作流已验收 |

近期代码包含语音杂音与上下文保护、工作区执行器以及 Hermes 到 Ark 的审批桥接。语音回答生成或播放期间，默认通过明确唤醒词或“直接说话”接受新输入，避免背景声音直接污染会话。

## 技术组成

- **客户端**：Swift 6、SwiftUI、AVFoundation/CoreAudio、EventKit。
- **后端**：Python、FastAPI、SQLite、Ollama；Python 执行器与 Swift 原生能力宿主共享 Skill 协议。
- **默认模型**：聊天 `qwen3.5:9b-mlx`，记忆向量 `qwen3-embedding:0.6b`；反馈模型默认关闭。
- **语音**：MLX-Audio，Qwen3-ASR-0.6B-8bit、Qwen3-TTS-12Hz-0.6B-CustomVoice-8bit，sherpa-onnx 唤醒与 Silero VAD。

文字和最终语音转写进入共同任务入口；Agent 根据启用的 Skill 调用 Python 工具或 macOS 原生宿主。需要确认的操作先生成预览，在应用中获批后执行并核验。语音停止播放不等于取消已经提交的任务。

## 本地运行

### 1. 环境与模型

完整语音功能面向 Apple Silicon Mac。需要 macOS 14+、支持 Swift 6 的 Xcode 工具链、Python（开发环境使用 3.13）、Ollama；可选语音安装还需要 `uv`。现有资源配置面向 24GB 统一内存开发机，不代表最低硬件要求已测定。

```bash
git clone https://github.com/RuikAn-n/Ark-Intelligence.git
cd Ark-Intelligence
python3.13 -m venv backend/.venv
backend/.venv/bin/python -m pip install -r backend/requirements.txt
ollama pull qwen3-embedding:0.6b
ollama list
```

确保 Ollama 正在运行，默认地址为 `http://127.0.0.1:11434`。聊天使用开发机已有的 `qwen3.5:9b-mlx` 模型名；仓库不包含其权重或创建流程，请先在本机准备该模型，不要假设这个名称可以直接从公共模型库下载。更换模型时需检查 `backend/configs/model.yaml`，以及 `backend/agent/memory_agent.py` 等模块中的固定模型名。

### 2. 启动后端与客户端

在项目根目录启动后端：

```bash
./scripts/run_backend.sh
```

另一个终端构建并打开应用：

```bash
./scripts/build_app.sh
open "build/Ark Intelligence.app"
```

构建脚本会同步原生能力目录、编译 debug 应用并进行本地 ad-hoc 签名。后端默认监听 `127.0.0.1:8765`。进入“Skill 管理”启用需要的能力；日历和提醒事项首次访问需要 macOS 授权。

可用 `ARK_PORT` 改变后端端口，并在启动客户端时通过 `ARK_API_URL` 配置对应地址。服务仅供受信任的本机客户端使用。

### 3. 可选：Sophie 语音

```bash
./scripts/setup_voice.sh
./scripts/run_voice.sh
```

首次安装会创建独立 `.voice-venv` 并下载模型到 `.voice-models`，需要网络和磁盘空间。语音服务默认监听 `127.0.0.1:8766`，需与聊天后端同时运行。应用中进入“语音对话”，允许麦克风权限，等待模型预热，再说“Hey Sophie”或点击“直接说话”。

`ARK_VOICE_PORT` 配置服务端口，`ARK_VOICE_URL` 配置客户端连接地址。模型加载后语音推理在本机执行；网络搜索仍需联网。

### 4. Hermes 本地能力

已有本地 Hermes lab 时，为 Ark 主对话准备完整接入：

```bash
backend/.venv/bin/python scripts/setup_hermes_runtime.py
```

重启后端后，在“Skill 管理”可看到并搜索 Hermes 技能。Ark 使用同一对话、记忆和任务入口按需读取技能指导与附件，实际工具操作在 Ark 任务栏审批。本机已验证模型主动发现技能、调用 Word 脚本生成并核验文件，以及本地 Chrome 页面操作。配置、能力边界和测试见 [Ark × Hermes 集成说明](docs/hermes-integration.md)。

`integrations/hermes/ark_bridge` 提供 Hermes 插件，复用 Ark 的动作与审批流程。在已配置好的本地 Hermes lab 中安装：

```bash
backend/.venv/bin/python scripts/install_hermes_bridge.py
bash scripts/hermes-lab.sh chat
```

安装脚本要求 `.hermes-lab/hermes-home/config.yaml` 已存在；它不是完整的 Hermes 环境安装器。该实验环境未随仓库提交，新克隆不能直接运行上述命令。版本、环境布局与既有验证见 [Hermes 开发记录](docs/hermes-lab.md)。桥接令牌不能批准操作或读取 Ark 私人记忆；系统写入仍需在 Ark 客户端确认。

## 数据与操作边界

- 长期记忆：`backend/memory/memory.db`。
- 任务、会话与令牌：默认在 `~/Library/Application Support/ArkIntelligence/runtime/`；后端支持 `ARK_RUNTIME_DIR` 覆盖。
- 工具工作区：默认在 `~/Library/Application Support/ArkIntelligence/workspace/`，与 runtime 目录相邻。
- 语音原始录音只在内存中处理；本地模型、数据库、令牌、实验环境和构建产物不作为本次源码成果提交。
- 本地 HTTP/WebSocket 使用令牌认证。工作区文件接口拒绝路径穿越和链接访问，写入绑定文件版本；shell 缺少系统隔离能力时拒绝执行。命令失败或超时可能已经修改工作区文件，需要读回核实。

## 验证与未完成事项

常用回归命令（在仓库根目录运行）：

2026-09-20 集成验证：后端 53 项通过（含真实 Hermes 和 macOS sandbox 集成测试），Swift 测试 10 项通过；本地模型技能发现、Word 脚本产出、Chrome 自动化和本地图像分析已通过实测。语音听感和长期记忆质量不在本轮重新评测范围内。

```bash
PYTHONPATH=backend backend/.venv/bin/python -m unittest discover -s backend/tests -v
PYTHONPATH=backend .voice-venv/bin/python -m unittest voice.test_session -v
swift test --package-path frontend --scratch-path /private/tmp/ark-tests -j 2
```

真实模型、联网和原生应用测试需要额外运行环境，参见 [测试指南](docs/testing.md) 与 [语音开发记录](docs/sophie-development.md)。自动化通过不能替代麦克风听感、系统权限或真实日历写入验收。

现有语音记录中的热 TTS 样本首音约 0.10–0.13 秒，仅覆盖合成环节；9B 模型首个可播文本约 2.19–2.63 秒。**完整对话 1.5 秒目标尚未达到**，真人端到端 P50/P95 与长时间误唤醒测试仍待完成，以上数据也不是本次重新测量结果。

后续重点包括语音端到端延迟与噪声场景调校、更多 Hermes 技能与自然语言端到端场景验收、日历/提醒事项重复项目处理，以及后台常驻、Shortcuts、Apple Events、Accessibility 和第三方插件隔离。

## 目录与文档

```text
frontend/       SwiftUI 应用、原生能力宿主与 Swift 测试
backend/        API、Agent、记忆、Skill 运行时、工具、语音与 Python 测试
skills/         内置技能清单及执行指导
shared/         Skill 协议 JSON Schema
integrations/   Hermes 桥接插件
scripts/        启动、构建、模型准备与验证脚本
docs/           开发进度、架构与测试说明
```

- [Skill 实现状态（2026-09-06 历史快照）](docs/implementation-status.md)
- [Skill 开发指南](docs/skill-development.md) · [系统开发计划](docs/skill-system-development-plan.md)
- [Sophie 语音进度与测试](docs/sophie-development.md)
- [Hermes / OMH 实验环境](docs/hermes-lab.md)
- [Ark × Hermes 本地 Agent 集成](docs/hermes-integration.md)
- [架构图 HTML](docs/architecture/ark-intelligence-architecture.html)（下载后用浏览器打开）

较早的开发文档保留当时的计划与测试数量；当前功能概况以本 README 和现有实现为准。
