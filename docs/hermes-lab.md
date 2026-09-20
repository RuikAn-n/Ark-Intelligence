# Hermes / OMH 开发测试环境

安装日期：2026-09-17。独立环境位于项目 `.hermes-lab/`，已加入 Git 忽略。

## 版本与布局

- Python 3.13.15；Hermes Agent 0.21.3，源码提交 `6005aa1fd9aac8b1024ace50fec8cd1c85a04bae`。
- OMH 2.0.3，固定提交 `f4b5bc2f4b95285669c121d396e598c1ad75ece8`。
- `hermes-agent/`、`oh-my-hermes/`：源码，均以 editable 方式安装。
- `venv/`：专用 Python 环境；`requirements.lock.txt`：安装版本快照（本地 editable 路径需配合上述源码版本）。
- `hermes-home/`、`omh-home/`：独立配置、记忆、技能和运行记录。
- `workspace/`：默认测试工作目录；`reports/`：安装、诊断和测试结果。

## 启动

在 Ark-Intelligence 根目录执行：

```bash
bash scripts/hermes-lab.sh chat
bash scripts/hermes-lab.sh doctor
bash scripts/hermes-lab.sh test
```

直接使用命令或开发源码：

```bash
source .hermes-lab/activate.sh
cd .hermes-lab/workspace
hermes chat --cli
omh model-chains show
```

Ollama 需运行于 `http://127.0.0.1:11434`。主模型为已有 `qwen3.5:9b-mlx`，全部 12 个 OMH 类别使用 `qwen-local-9b` / `custom` / `low`。这个 Ollama 别名通过 copy 创建，复用原模型权重；用于绕过 OMH 标识符不允许冒号的限制，不是新增模型训练或下载。没有配置云端回退，也未启用外部编码执行器。

Hermes 当前版本要求至少 64,000 token 上下文，因此测试配置使用 65,536，而不是 Ark 的 8K。Ollama 元数据报告该模型支持 262,144；这不代表已完成长上下文压力测试。默认最多 8 轮，采用经典 CLI；现代 TUI、桌面端和菜单栏不在本轮安装验证范围。

## 验证结果

- 记忆、attention tiers、模型路由：186 tests passed，102 subtests passed。
- `omh memory recall-suite`：16/16 场景通过，属于离线夹具回归。
- Hermes 真实本地聊天返回“本地 Qwen 测试成功”，0 次工具调用，约 24 秒；观察到 OMH session-end 记忆整理提示。
- 路由状态验证：provider routes applied；所有类别映射到本地 Qwen。
- 初次 doctor：ok=true，0 blocking；真实插件加载器注册检查通过。

初次安装时尚未验证工具调用正确率、多模型调度或长期记忆真实会话准确率。后续 Ark 工具专项验证见下节。启动时提示可选 tirith 未安装，命令扫描使用模式匹配；无工具测试还出现 Unknown toolsets: omh 提示，插件工具可用性需在后续专项测试核验。不要把这次聊天通过视为全部 OMH 工作流通过。

建议下一轮：在测试目录验证一项只读 OMH 工具调用；再测试“候选记忆→审核→新会话召回→更新/过期”；最后比较本地模型参数与提示词的成功率和延迟。

## 维护

本轮通过源码 editable 安装，开发修改 Python 文件后重启会话；新增 OMH 包文件时可能需要重新安装 editable 包。不要直接运行 `omh update` 破坏固定版本对照，升级时分别选择并记录两个仓库的新提交、重装依赖、重新 setup 和测试。

测试状态与配置都在 `.hermes-lab` 中，现有 Ark 后端环境及记忆数据库保持独立。此目录隔离数据，不是操作系统沙箱；启用 terminal 工具后仍有本机账户权限。

## Ark 桥接与工作区能力（2026-09-20）

已安装项目内的 `ark-bridge` Hermes 插件，注册 20 个 Ark 动作及 2 个状态查询工具。提醒事项、日历和应用动作使用 Ark 原生宿主；文件和命令使用 Ark 工作区执行器。提醒事项路由指导明确要求使用 `ark_reminders_*`，不能用 cron 代替系统提醒事项。模型是否遵循指导仍需逐次核验工具结果。

重新安装插件或修改桥接源码后，在项目根目录执行：

```bash
.hermes-lab/venv/bin/python scripts/install_hermes_bridge.py
```

测试时分别启动后端、Ark 应用和新的 Hermes 会话（已经运行的后端无需重复启动）：

```bash
./scripts/run_backend.sh
# 另一个终端
./scripts/build_app.sh
open "build/Ark Intelligence.app"
bash scripts/hermes-lab.sh chat
```

保持 Ark 的“主对话”页面打开，并在 Skill 管理中启用相应技能。当前桥接固定连接 `127.0.0.1:8765`。主对话每 3 秒发现 Hermes 外部任务，然后通过事件流接收进度；写入和所有终端命令在右侧任务栏展示预览并等待确认。Hermes 返回 `waiting_approval` 时尚未执行；确认后请让它使用 `ark_run_status` 查询原任务，不能重新提交写入。

桥接使用独立的 `runtime/hermes-token`，只允许访问 Hermes 集成端点，不能批准操作、启用技能或访问私有记忆接口。请求 ID 支持去重；提交响应丢失时返回可查询的任务 ID，不自动重放写入。原生写操作没有明确读回验证时返回结果未知。

### 工作区范围

Ark 工作区是 `~/Library/Application Support/ArkIntelligence/workspace`，与 `.hermes-lab/workspace` 不同。提供列举根目录、读取相对路径文件、审批后写入文件和执行命令。文件写入绑定预览时的 SHA256 版本，审批后有变化则拒绝覆盖。拒绝绝对路径、上级路径、隐藏路径、符号链接、硬链接和特殊文件。读取文件最多 1 MiB，内容返回最多 6000 字符，写入最多 6000 字符。

终端通过 macOS `sandbox-exec` 执行系统 shell，禁止网络及工作区外用户文件访问，最长 60 秒，标准输出和错误各截取 6000 字节。超时和取消会终止进程组。不支持交互终端、联网安装依赖或长期运行服务；工作区外的资料需先由用户复制进来。命令结果的 `verified` 表示退出码为零，业务结果仍需通过读取文件或其他工具核验。

上述约束只适用于 `ark_workspace_*`。Hermes 自带 terminal 工具仍是另一条执行路径，插件中的优先路由指导不会把它变成 Ark 沙箱。

### 已验证

- 本地 Qwen 经 Hermes 调用 Ark，成功读取真实提醒清单。
- 通过桥接在指定私人清单创建临时提醒，Ark 界面审批后读回，再查询、审批删除并验证清理；没有修改原有提醒。
- 通过桥接审批写入测试文件，再审批执行 `cat`，退出码为零且输出与原文一致。
- 40 项 Python 测试通过，包含真实 macOS 沙箱的越界读写、联网拒绝、超时和取消测试；9 项 Swift 测试通过，包含外部任务审批事件流。应用构建和签名完成。

本机报告位于 `.hermes-lab/reports/`：`ark-tests.txt`、`ark-swift-tests.txt`、`ark-build.txt`、`ark-native-smoke.txt`、`reminder-ui-smoke.json`、`workspace-ui-smoke.json`。这些验证覆盖接口与选定的真实流程，不代表自然语言提醒解析、长期记忆、多模型调度已完成全面评测。

## 自然语言提醒路由修复（2026-09-20）

真实用户请求暴露了与 Hermes 自带 `apple-reminders` 技能的冲突：该技能要求 `remindctl`，而 Ark 使用原生 EventKit，完全不依赖这个 CLI。默认工具搜索还会延迟加载 Ark 的实际工具定义，导致本地 Qwen 选择错误执行路径。安装脚本现会在独立 lab 配置中禁用 `apple-reminders`，并设置 `tools.tool_search.enabled: off`，让启用的工具定义直接对模型可见；代价是增加提示词长度。桥接指导也明确要求先查询 Ark 提醒清单，不检查或安装 remindctl。

安装后必须退出旧 Hermes 会话，再运行 `bash scripts/hermes-lab.sh chat` 开始新会话。不要用 `--resume` 或 `--continue` 恢复含旧技能内容的会话。此设置仅影响项目 lab，不修改全局 Hermes 或上游技能文件。

针对当前 9B 模型，新增精简入口：

```bash
bash scripts/hermes-lab.sh ark
```

该入口只启用 Ark 工具集；OMH 插件和配置保留，但 Hermes 会因未启用 memory 工具集而不注入其记忆提示和工具。需要 Hermes 自带终端等完整工具时仍使用 `chat` 入口。实测完整工具模式约 34K 输入 token，成功查到清单后仍可能只输出计划；精简模式约 5.8K，指定私人清单的请求实际调用了 `ark_reminders_list_lists` 和 `ark_reminders_create_reminder`，正确提交 `2026-09-22T10:00:00+08:00` 并返回 `waiting_approval`，Ark 界面显示对应预览。回归测试卡片已拒绝，未创建真实提醒。

该次模型回复仍混用了“已创建”和“等待审批”，说明自然语言状态表达尚不可靠。必须以 Ark 工具返回及任务栏状态为准；待审批不代表已写入。报告：`.hermes-lab/reports/ark-reminder-direct.jsonl`（完整工具对照）和 `ark-reminder-focused.jsonl`（精简工具回归）。

### Reasoning-only 提前结束修复

后续交互日志确认 Hermes 的 `Reasoning-only clean stop` 分支把 Qwen 的纯思考输出提升成最终回复，导致查询清单后未提交创建。`ark` 入口现固定传入 `--reasoning none`（完整 `chat` 入口不变），避免该模型在当前工具测试中只输出思考。桥接每轮用 Python 日期运算提供上海时区的今天、明天、后天，覆盖跨月、跨年、闰年及 UTC 日期转换单测。

使用用户原句“后天上午10点，提醒我关注学生会面试通知，放入私人清单。”回归，实际调用清单查询及创建，参数为 `2026-09-22T10:00:00+08:00`，返回 `waiting_approval`，并在 Ark 界面确认可见对应卡片。报告为 `ark-reminder-nothink.jsonl`。模型仍可能把“已提交待审批”表述成“已创建”，不能据此判断业务完成；程序日期上下文也不等同于服务端对自然语言日期的强校验。此修复已通过该次真实回归，尚不能保证所有表达或多轮会话的成功率。

### 文件位置与用户验收

用户根据生成文档的项目背景内容，确认本轮记忆使用符合预期。该反馈属于用户验收，不等同于逐条检索调用链验证。文件实际位于 Ark 专用工作区，模型曾误报为桌面；本轮已在审批预览和写入结果增加 `absolute_path`，并补充禁止把工作区冒充桌面的工具说明与系统提示。指定工作区外位置时应先说明能力限制，而不能静默替换目标。
