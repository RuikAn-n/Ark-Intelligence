# Ark Intelligence Skill 系统开发计划（待审查）

日期：2026-09-05。状态：仅完成代码检查与设计，尚未开始实现。

## 1. 目标与建议范围

建立可持续接入新技能的统一协议，并让现有本地助手能通过这台 Mac 的系统接口完成真实操作。

建议首版交付：

- Skill 的发现、校验、启停、权限状态、调用与执行记录。
- 日历查询、新建、改期、删除；提醒事项查询、新建、修改、完成、删除。
- 应用查找、查看运行状态、打开、切换到前台、正常退出。
- 对话中的多步调用、必要澄清、操作预览、取消及真实结果反馈。
- 一个示例技能与接入文档，证明新增技能不需要修改 Agent 主循环。

“类似 Siri”在首版指自然语言驱动系统操作。先完成文字入口；语音与文字后续共用同一执行链路。首版在 Ark 应用和本地后端运行时提供能力，日历与提醒事项保存后的通知由系统负责。应用退出后继续执行任务、定时唤醒、系统 Siri 唤起 Ark 属于后续范围。

## 2. 代码库检查结果

检查基于当前工作区，包含用户尚未提交的修改。

| 模块 | 已有实现 | 本次开发需要补齐 |
| --- | --- | --- |
| `frontend/Package.swift` | Swift 6、SwiftUI、最低 macOS 14、单一 executable target | 正式 `.app` 构建入口、Bundle ID、Info.plist、签名与权限配置、测试 target |
| `backend/agent/core.py` | Ollama、本地记忆、辅助反馈、SSE 事件、进程内对话历史 | tools 注入、tool_calls 解析、多轮执行、暂停恢复、任务状态和取消 |
| `backend/api/server.py` | `/chat`、`/chat/stream`、记忆 CRUD、结束会话 | Skill API、执行任务 API、原生执行通道、会话隔离与本地鉴权 |
| `backend/skills/`、`backend/tools/` | 空目录 | 技能注册表、标准、策略及执行适配器 |
| `Core/Models/Models.swift` | Skill 仅有 UUID、名称、描述、图标、启用开关 | 稳定标识、版本、动作列表、权限、可用性、调用状态 |
| `Features/Skills/SkillViews.swift` | 列表和启停 UI、Repository 抽象 | 真实数据、详情、权限说明、失败与执行记录 |
| `App/AppState.swift` | 聊天和记忆已用 Live Repository | Skill 仍注入 MockSkillRepository；替换为真实仓储 |
| `Core/Services/VoiceService.swift`、语音页面 | 占位协议、Mock、不可用状态 | 后续真实音频输入输出 |

相关问题与实施约束：

1. `run_main()` 只读取 content/thinking，没有传入 tools，也不处理 tool_calls。历史被拼入提示词，尚无结构化工具消息历史。
2. 当前回答内容先积累再统一发送，工具进度需要改为按事件实时推送。
3. 后端只有一个全局 ArkAgent；前端恢复历史只恢复 UI。增加工具后，必须用 session_id 隔离上下文，并明确恢复会话的后端行为。
4. `ChatViewModel` 只在 thinking 状态阻止发送，streaming 时仍可能重复发送；SSE 网络任务也缺少完整的取消传播。执行系统上线前需要修复。
5. 当前 API 未见鉴权实现，`ARK_API_URL` 可覆盖地址。新增系统执行能力需要绑定可信本地后端，不能自动向任意配置的远程地址提供原生控制通道。
6. 未发现依赖清单、测试目录及应用权限配置；`.build` 已被 Git 跟踪，工作区存在大量构建产物变化及现有源码修改。实施时保留这些源码工作，构建使用独立输出目录；清理已跟踪产物作为独立变更处理。
7. 原 `frontend/firstplan（已完成）.md` 是前端阶段计划。本计划进入后端 Skill 阶段，明确提出修改 `agent/core.py` 与 API 的原因和范围；前端 Mock 无法完成真实工具执行。

本机只读检查得到 macOS 26.4，Xcode 已安装；项目最低目标仍为 macOS 14。已核对本地 SDK 中 EventKit 接口的 macOS 14 可用性。尚未编译、启动服务、调用模型、读取私人日程或触发系统权限，因此不宣称运行验证已通过。

## 3. 总体架构

```text
用户文字 / 后续语音
        ↓
SwiftUI ChatViewModel ── HTTP + SSE ── FastAPI / 会话与任务服务
        │                                  ↓
        │                           Agent 工具执行循环
        │                                  ↓
        │                       Skill Registry + Policy Engine
        │                                  ↓
        │                            Executor Router
        │                           ↙              ↘
        │                 Python 内置执行器      Native Bridge
        │                                          ↕
        └─ 操作预览与授权             由 Swift 主动建立的本地 WebSocket
                                                   ↕
                                      Swift NativeCapabilityHost
                                                   ↓
                                    EventKit / AppKit 系统接口
```

职责分工：

- Python：加载技能、提供动作 Schema、编排调用、验证参数、检查授权、保存任务与结果、继续模型推理。
- Swift：查询真实系统权限、展示系统授权、执行原生接口、生成或复核具体操作预览、验证操作后的系统状态。
- SwiftUI View：展示信息和提交用户选择；不直接写日历或运行系统命令。
- Registry 的数据为技能定义来源；Swift 执行器维护自身可支持的动作 allowlist。双方握手比对版本与能力，清单不能凭空授予原生能力。

原生执行宿主首版随 Ark `.app` 运行，避免增加独立后台服务。聊天使用已有 HTTP/SSE，原生桥接使用独立 WebSocket，不能在聊天 SSE 中收到一个动作就直接执行。界面断开、任务恢复、审批和动作执行分别管理。

建议首版面向个人本机使用，采用签名的 `.app`、非 App Sandbox 发行方式，并保留 macOS 隐私授权约束；签名身份以开发环境可用条件配置。App Store 沙盒适配单独评估，Phase 0 验证该发行方式的权限行为。

## 4. 统一 Skill 标准：Ark Skill v1

明确区分：Skill 是可安装的技能包及使用指导；Action 是可调用的原子操作；Executor 是实际运行 Action 的实现。

推荐目录：

```text
skills/calendar/
  manifest.json            # 机器可读定义，必需
  SKILL.md                 # 适用场景、参数解释、组合流程与示例
  schemas/                 # 各 action 的输入输出 JSON Schema
  tests/                   # 契约样例和测试数据
```

`SKILL.md` 用来指导模型选择和组合能力；它不能替代参数校验、权限或可执行代码。内置 Swift 能力随应用编译；首版动态加载的是合法清单和指导文档，不执行任意下载脚本。

### 4.1 清单必填字段

| 字段 | 约定 |
| --- | --- |
| schema_version | Skill 协议版本，首版 `1.0` |
| id | 稳定命名空间，如 `ark.calendar`，不用随机 UUID |
| version | 技能语义版本，与协议版本分开 |
| name / description / icon | 展示信息 |
| compatibility | 最低 Ark 版本、平台、最低系统版本、依赖能力 |
| instructions | 包内指导文档路径，限制在包目录以内 |
| actions | 动作定义列表 |

每个 action 必须定义：`id`、描述、`input_schema`、`output_schema`、`executor`、`handler`、所需 permissions、`side_effect`、`confirmation`、`timeout_ms`、`retry_policy`、`idempotency`。

例如 `calendar.update_event` 的参数必须包含明确目标引用、修改字段和预期版本；业务语义上的“明天那个会”必须先通过查询定位。完整 Schema 在 Phase 1 冻结，采用 JSON Schema 2020-12，并规定可映射给模型的兼容子集。跨字段规则由执行器补充校验。

版本规则：拒绝不兼容的协议主版本；向后兼容的可选字段使用小版本；破坏输入输出契约的动作变更提升技能主版本。每个任务固定技能版本和清单摘要，运行中更新不改变当前动作。

命名映射由 Router 将规范 action ID 转为模型支持的函数名称并检查冲突；业务代码统一使用规范 action ID。

### 4.2 统一调用与返回

调用信封包含：`protocol_version`、`session_id`、`run_id`、`call_id`、`skill_id`、`skill_version`、`action_id`、`arguments`、`deadline`、`idempotency_key`。模型只产生动作名与业务参数；身份、授权、截止时间及幂等键由运行时生成。

返回信封包含：对应关联 ID、`status`、`data`、`error`、`started_at`、`finished_at`、`verification`，以及可选的变更前后摘要。

统一错误码至少包括：`INVALID_ARGUMENT`、`PERMISSION_DENIED`、`SKILL_DISABLED`、`CAPABILITY_UNAVAILABLE`、`TARGET_NOT_FOUND`、`AMBIGUOUS_TARGET`、`CONFLICT`、`TIMEOUT`、`CANCELLED`、`EXECUTION_FAILED`、`RESULT_UNKNOWN`。

成功必须来自执行器和必要的读回验证。模型回复、退出请求已发送、网络 ACK 都不等于操作成功。

### 4.3 接入流程

新增技能：编写清单与指导文档 → 通过 Schema/版本/依赖检查 → 注册已支持的 executor handler → 添加契约测试 → 启用 → 自动出现在 Skill UI 与模型候选工具中。

复用已有动作的组合技能只需技能包；新增 Python 原生业务能力需要 handler；新增 macOS 能力需要 Swift handler 并重新构建应用。三种接入方式都不修改 Agent 主循环或通用列表 UI。

首版支持内置 `native`、`python` 两种 executor；未来 MCP 或 Shortcuts 可以作为新 adapter 接入。MCP 适配与第三方代码隔离实现之前，不把外部插件当作安全可执行模块。

## 5. Agent 执行循环与任务生命周期

一次操作的流程：

1. 接收用户消息、session_id、设备当前时间与时区，读取已启用且可用的技能。
2. 按任务选择相关动作，将结构化 tools 与完整会话消息交给主模型。
3. 累积本轮 streaming tool_calls，完成后校验名称、参数、权限与执行预算。
4. 目标不明确时返回候选并等待用户选择；需要审批时先生成具体变更预览。
5. Router 调用对应执行器；发出实时进度事件。
6. 记录真实结果，将 assistant tool_calls 与 tool 结果加入消息历史，再继续推理。
7. 没有后续动作时生成最终回答；说明成功项、失败项和仍需处理项。

首版每个会话串行执行，建议默认最多 8 轮模型工具循环、16 次动作调用；读取动作在后续有需要时再并行优化。超出预算返回可继续的中止原因。

任务状态：`queued → planning → waiting_input / waiting_approval → executing → verifying → succeeded / failed / cancelled / interrupted / result_unknown`。等待后返回执行状态；状态转换必须由服务端验证。

- 将会话、任务、调用、审批、事件和技能启停状态保存在独立运行数据库，避免改动现有记忆数据库结构。
- SQLite 表建议为 sessions、runs、calls、approvals、run_events、skill_settings；建表与迁移有版本号。
- 原生端另存最小执行日志，执行前标记 call_id，执行后保存结果；断线重连返回已完成结果。
- 外部系统写入与本地日志不能形成原子事务。遇到崩溃窗口先读回核实；不能核实就标记 RESULT_UNKNOWN，不承诺 exactly-once，也不自动重放写操作。
- 幂等键绑定一次用户意图与规范化参数；用户主动要求再创建一次会生成新键。
- 取消时终止后续动作及可取消的推理/网络任务；已经完成的外部变更保留事实记录，不虚报回滚。
- 多步骤任务不假装具有事务性；报告部分成功。撤销仅用于明确支持且状态未被外部修改的动作。
- 当前恢复历史功能改为按 session_id 恢复后端上下文。旧记录可迁移为新的会话文本上下文，不能恢复为可重放的执行指令。

Ollama 官方支持结构化工具调用与 streaming 聚合，但当前 `qwen3.5:9b-mlx` 标签的实际服务、模板和调用能力还未验证。Phase 0 用无副作用 mock 工具探测。若不支持，优先修正调用适配或选用经验证的本地工具模型；只有经过测试的严格结构化输出模式可作为备选，普通文本不能直接作为命令执行。[Ollama 文档](https://docs.ollama.com/capabilities/tool-calling)

辅助反馈模型保留现有职责，但操作进度与成败以任务事件为准，禁止根据推测播报“已完成”。工具返回和技能文档是数据/指导，不能修改授权策略；日程描述等外部文本不作为新的用户指令。

## 6. macOS 首批能力

| 技能 | 首版 Action | 原生接口与处理要求 |
| --- | --- | --- |
| 日历 | list_calendars、list_events、create_event、update_event、delete_event | EventKit / EKEventStore；读取与修改需要日历 full access |
| 提醒事项 | list_lists、list_reminders、create_reminder、update_reminder、complete_reminder、delete_reminder | EventKit / EKReminder；单独请求 reminders 权限 |
| 应用管理 | find_apps、list_running_apps、open_app、activate_app、quit_app | NSWorkspace / NSRunningApplication；以本机解析出的 Bundle ID 与 URL 定位 |

EventKit 是系统支持的日历/提醒事项入口，不能直接修改系统数据库。只写权限不足以支持查询和改期；权限使用请求及状态检查按实际访问需求实现。[Apple EventKit](https://developer.apple.com/documentation/eventkit/accessing-the-event-store)

### 日历和提醒事项细节

- “明天”“下周三”相对客户端当前时间解释；保存绝对时间、IANA 时区及全天属性。时间或目标存在歧义时澄清，不能自行编造结束时间。
- 首版自动处理普通单次日程。重复日程可查询，但修改/删除重复系列暂不自动执行，返回明确限制，后续再增加“仅本次/之后所有”的 scope。
- 检查日历是否可写、起止时间是否合法、目标是否仍存在；修改前复读并对比预期状态，发生外部变更时重新预览。
- 系统事件标识可能随同步变化；使用原生端管理的引用及必要的日历/时间信息重新定位，定位不唯一时拒绝写入。
- 冲突检测展示现有占用，不擅自挪动其他日程。
- 首版不自动发送会议邀请；涉及与会者、共享日历或可能触发同步通知的修改，显示影响范围并要求确认，无法可靠判定时停止自动修改。
- 提醒事项区分只有日期与带具体时间的到期设置；重复提醒的编辑也先限制。
- 验证写入成功后从 EventKit 读回目标；说明本地保存结果，不能宣称远端账号已经同步完成。

### 应用操作细节

- 中文名称、英文名称及别名先解析为实际安装目标；多个版本或同名应用出现时让用户选择。
- 打开应用复用已运行实例；激活或启动后检查实际运行状态。
- “关闭软件”按正常退出理解；关闭单个窗口属于后续 UI 自动化能力。
- `terminate()` 只表示正常退出请求已发出，需要观察 isTerminated/系统通知确认。应用可能弹出未保存提示，显示“等待你处理应用提示”，不自动强制结束。[Apple terminate](https://developer.apple.com/documentation/appkit/nsrunningapplication/terminate())
- 首版排除强制退出、杀进程、退出 Ark 自身及关键系统进程。显式处理应用不存在、已退出及退出超时。

## 7. 权限与执行策略

三层分别处理：用户启用技能、Ark 对当前操作的授权、macOS 系统权限。启用技能不等于允许任意操作；日历权限已授予也不能绕过具体动作策略。

建议默认策略：

| 操作 | 默认行为 |
| --- | --- |
| 查询日程/提醒、查看运行状态 | 已有系统权限时直接执行 |
| 打开或激活明确指定的应用 | 直接执行并显示结果 |
| 明确要求正常退出指定应用 | 直接发送正常退出请求，等待实际结果 |
| 新建、修改、删除日程与提醒 | 先展示结构化预览后执行；设置中可为明确范围的新建/修改保存授权，避免每次确认 |
| 删除、批量修改、共享日程变更 | 默认每次确认具体对象与范围 |
| 缺少参数、同名目标、多种时间解释 | 澄清，不将其包装为权限询问 |

审批绑定 run_id、call_id、参数摘要、目标版本和到期时间。参数改变、目标更新或审批过期后需要重新生成预览。模型不能伪造审批字段。

本地桥接：后端只监听 loopback；启动器创建随机会话密钥，通过受限文件或继承通道交给双方，不写入仓库、URL 或日志。HTTP/SSE 与 WebSocket 均鉴权；验证 Host/Origin（存在时）、连接身份、消息大小、动作 allowlist 与协议版本。浏览器页面不能凭本地地址取得系统操作能力。

系统执行通道只允许配对的本地后端；`ARK_API_URL` 指向远端时不建立 Native Bridge。启停与权限撤销在执行前再次检查；禁用技能取消待执行动作，已开始的调用按取消规则处理。

Info.plist 加入日历/提醒事项用途说明；具体 keys 和请求方式对照 macOS 14+ SDK 校验。后续使用 Apple Events、语音、麦克风或辅助功能时再增加对应权限，不在首版启动时统一索取。

执行记录保存必要参数、目标、变更摘要与错误；令牌、完整日历描述及无关个人信息不进入普通日志。工具读取的数据不自动转为长期记忆。

## 8. 接口与前端改动

建议新增 API：

| 接口 | 用途 |
| --- | --- |
| `GET /skills`、`GET /skills/{id}` | 清单、版本、动作、权限与可用状态 |
| `PATCH /skills/{id}` | 保存启停及允许配置 |
| `POST /runs` | 发起带 session_id 的可追踪任务，返回 run_id |
| `GET /runs/{id}` | 查询当前状态与结果 |
| `GET /runs/{id}/events` | 可按事件序号恢复的 SSE |
| `POST /runs/{id}/approvals` | 批准/拒绝某个具体待审批操作 |
| `POST /runs/{id}/input` | 提交消歧或缺失参数 |
| `POST /runs/{id}/cancel` | 请求取消 |
| `WS /native/bridge` | 原生能力握手、执行请求、结果、权限状态与重连 |

现有聊天和记忆 API 保持兼容；新的前端操作流程接入 `/runs`。旧聊天调用遇到需要原生执行或交互的任务时，返回可理解的升级/能力限制，不能绕开审批或无限等待。`/session/end` 增加可选 session_id，兼容旧字段并隔离正在执行的会话。

SSE 增加 session_id、run_id、递增 event_id 与类型化 payload；保留已有事件适配。新增事件覆盖 task_state、tool_started、approval_required、input_required、tool_finished、tool_failed。重连仅重放事件，不重放系统动作。

前端新增 LiveSkillRepository、SkillDetailView、NativeCapabilityHost、权限服务与工具执行卡片。卡片展示动作、明确目标、修改前后、状态与结果；用户能取消任务、提交选择和查看历史。

将 ChatStreamEvent 从通用可选字段扩展为可兼容的类型化事件模型。统一处理 loading/error/cancelled/permission_denied/unavailable；修复重复发送与网络任务取消。历史记录保存工具执行摘要，避免恢复对话时重复执行。

## 9. 建议文件布局

```text
shared/skill-protocol/v1/             # Schema、错误码、跨语言样例
skills/{calendar,reminders,applications,example}/
backend/skills/{registry,manifest,policy}.py
backend/tools/{router,base,native_bridge}.py
backend/agent/{tool_loop,session_service,run_service}.py
backend/runtime/{database,migrations}/
backend/api/{skills,runs,native}.py
backend/tests/{skills,agent,api}/
frontend/ArkIntelligence/Core/Skills/
frontend/ArkIntelligence/Core/Native/{Calendar,Reminders,Applications}/
frontend/ArkIntelligence/Features/Skills/
frontend/ArkIntelligence/Features/Chat/ToolExecutionCard.swift
frontend/ArkIntelligenceTests/
frontend/ArkIntelligence.xcodeproj/    # 或等价可复现的 app 构建配置
docs/skills/                         # 开发指南、权限矩阵、测试指南
```

必要修改集中在 `agent/core.py`、`api/server.py`、前端 Models/Networking/AppState/ChatViewModel。保留记忆模块业务语义；运行状态使用独立数据库。具体文件拆分允许实施时调整，模块职责和协议边界保持一致。

## 10. 分阶段交付与验收

以下是顺序与粗估，不是固定工期承诺；不含后续语音等扩展阶段。

| 阶段 | 工作 | 可审查交付与通过条件 | 粗估 |
| --- | --- | --- | --- |
| P0 可行性与基线 | 依赖清单、现有聊天基线、无副作用模型调用探测、app 打包/权限方案、工作区变更保护 | 模型能稳定返回正确 mock tool_calls；原生桥接最小原型及权限请求可验证；明确兼容性问题 | 1–2 人日 |
| P1 标准与注册表 | 协议 Schema、清单加载、版本/依赖检查、启停持久化、模板和 SDK 边界 | 两个不同 executor 的 mock 动作通过同一契约；非法或冲突清单被拒绝 | 2–3 人日 |
| P2 任务与原生通道 | session/run/call、工具循环、鉴权、审批、取消、事件恢复、原生宿主 | mock 多步调用闭环；错误、断线和重复结果不引发重复执行；旧聊天回归通过 | 3–5 人日 |
| P3 系统技能 | 应用管理、日历、提醒事项、时间与目标解析、真实结果验证 | 在隔离测试日历/提醒列表及测试应用上通过正常与失败路径 | 3–5 人日 |
| P4 UI 与完整交付 | Skill 详情、权限状态、执行卡片、历史、接入指南、完整验收 | 真实 Skill 页面替换 Mock；用户自然语言完成首版场景；第三个示例接入无需改主循环 | 2–3 人日 |

合计建议预留约 11–18 人日，由 P0 结果重新校准。第一个可运行里程碑是“打开指定应用并回报实际结果”，随后交付日历和提醒事项，避免直到最后才发现桥接或模型不兼容。

## 11. 验证方案

不依赖真实模型的自动测试：

- 清单验证、重复 ID、不兼容版本、目录越界、禁用技能、未经声明的动作。
- Python/Swift 共享 JSON fixtures，验证编码、解码、错误码和协议版本。
- 模型 mock 的单步、多步、无效参数、超出预算、失败后回答、伪造授权及注入文本。
- 事件重连、重复 call_id、审批后参数变化、权限撤销、取消传播、写入后断线、重启后未知结果。
- 日历跨时区/夏令时/全天事件、同名目标、只读日历、外部修改冲突；应用已运行/已退出/正常退出失败。

本机集成与产品验收：

- “打开日历，再打开 Safari”：顺序执行并显示结果；不存在应用不能报告成功。
- “看看明天有哪些安排”：按设备时区查询，空结果与无权限分别显示。
- “把明天下午的项目会推迟一小时”：先定位；多候选时选择；预览改期；执行后读回。
- “明天下午三点提醒我交材料”：使用 Reminders，展示具体日期和时区，保存后读回。
- “退出文本编辑”：正常退出；有未保存提示时等待处理，禁止强退。
- 关闭技能、拒绝系统权限、拒绝操作、过程中取消均可恢复正常聊天。
- 在写入后模拟桥接断线，确认不会重复创建日程，无法核实的结果可见。
- 原聊天、记忆查看与修改、历史保存和恢复无功能回退。

建议固定至少 30 条中文命令及歧义/失败样例评估真实本地模型；执行层的未授权写入、跨会话串扰、重复写入测试必须全部通过。模型正确率与耗时先实测报告，再决定是否需要模型适配。

首版发布需在本机 macOS 26.4 完成真实操作验收；最低 macOS 14 若没有实际测试环境，标明“构建目标支持，运行待验证”，不把 SDK 可用性当作真机验证。

## 12. 后续能力

1. 语音：按键说话、转写、确认界面、结果播报；先验证设备与语言的本地识别能力，无法离线时明确显示服务依赖；复用 `/runs`。
2. Shortcuts：只运行用户选定的快捷指令，参数化调用，处理等待输入和超时；其实际副作用需单独说明，不能沿用普通只读工具授权。[Apple 命令行快捷指令](https://support.apple.com/guide/shortcuts-mac/apd455c82f02/mac)
3. Apple Events：为支持脚本的应用增加固定动作适配器与对应权限，不暴露任意 AppleScript 执行入口。[Apple 用途说明](https://developer.apple.com/documentation/bundleresources/information-property-list/nsappleeventsusagedescription)
4. Accessibility：再支持窗口、菜单和控件操作，独立考虑辅助功能授权、目标校验和操作验证。
5. 后台任务：需要在 Ark 退出后运行时，再设计独立宿主、生命周期与唤醒机制。
6. MCP 与外部技能：增加传输适配、来源管理、权限声明与进程隔离；另做第三方插件安装与升级机制。

## 13. 本次待审查的建议决策

- 采用“Python 编排 + Swift 原生执行”，首版宿主内置于 Ark `.app`。
- 采用“manifest + JSON Schema + SKILL.md + Executor”统一标准。
- 首版交付日历、提醒事项和应用管理；语音及广泛 UI 自动化后续实现。
- 采用第 7 节默认授权策略，支持为范围明确的操作记住授权。
- 同意为上述能力扩展 Agent/API 和 app 构建配置，现有记忆业务保持兼容。

本次仅新增本计划文件，没有修改实现代码、运行系统操作或变更现有工作区内容。
