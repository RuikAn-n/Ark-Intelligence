# macOS 通知感知：手动阶段

本阶段新增 `ark.notifications` Skill、原生 AX 采集器、统一 Ark Event、本机 SQLite 记录和“智能总结”页面。微信是首个验收目标；采集、存储、模型接口均不依赖微信。

## 使用

1. 重启后端，运行 `./scripts/build_app.sh`，重新打开 `build/Ark Intelligence.app`。
2. 在 Skill 管理启用“通知感知与总结”。默认关闭。
3. 打开“智能总结”，点击“辅助功能授权”，在 macOS 系统设置中允许 **Ark Intelligence**。开发签名改变后可能需要移除旧条目并重新授权。
4. 选择最近 1 小时、24 小时、今天或自定义时间段；应用名称留空查询所有来源，填写时精确匹配采集到的名称。
5. 勾选本次采集许可，点击“智能总结”。Ark 尝试通过系统时钟菜单项打开通知中心，并读取它暴露的通知卡片；无法自动打开时按界面提示手动打开。折叠分组需要手动展开。
6. 可使用“总结已采集记录”重试摘要，无需再次访问其他应用；展开“核对原始通知”检查来源。清空采集库不会清除系统通知，也不会删除对话中先前引用的通知内容。

没有后台轮询、启动登录项、AXObserver、定时任务或自动回复。页面离开后已发起的摘要可以继续完成。

## 能力边界

这不是完整系统通知历史接口。Apple 的 [getDeliveredNotifications](https://developer.apple.com/documentation/usernotifications/unusernotificationcenter/getdeliverednotifications(completionhandler:)) 只获取调用应用自身的通知。跨应用采集通过 [AXUIElementCopyAttributeValue](https://developer.apple.com/documentation/applicationservices/1462085-axuielementcopyattributevalue) 读取界面；可用属性取决于目标程序和系统版本。

- 当前仅采集通知中心暴露的卡片，不读取微信聊天数据库、不抓取完整会话、不访问系统私有通知数据库。
- 已清除、未加载、隐藏预览、折叠分组里的内容可能缺失。不会点击消息、回复、关闭或清空通知。
- 使用通知 subrole 识别卡片，避免将天气等桌面组件误识别。macOS UI 标识没有稳定公开契约，未知结构会返回明确错误，不返回虚构通知。初始 subrole 兼容参考了 [PingPlace 的实测结构报告](https://github.com/NotWadeGrimridge/PingPlace/issues/44)；这不是 Ark 的实机验收结论。
- 单次最多扫描 2500 个节点、24 层、约 8 秒并返回 500 张卡片；AX 消息本身也有超时。标题最多 1000 字、正文最多 4000 字。达到限制时提示分批采集。
- 支持中文/英文的“刚刚、N 分钟前、N 小时前”等相对时间，精度标为 approximate。无法可靠识别的日期保留原始标签并标为 unknown；不会用 observed_at 补造接收时间。
- 范围为 `[start, end)`，要求显式时区，最多 31 天。unknown_time_count 统计所选区间内采集、但无法确认接收时间的记录；它们不参与接收时间摘要。
- 没有稳定源 ID 时使用内容和估计接收分钟去重；未知时间按采集日期去重。相同内容可能合并，相对时间重新估计也可能产生重复；不会将条数宣称为真实消息总数。
- 每次摘要最多 500 条；超出时拒绝并提示缩短区间，不静默丢弃。分批摘要保留每组输出，界面提供全部源事件用于核对。

## 代码与数据流

```text
用户手动操作
  → NotificationSummaryViewModel
  → ApplicationEventAdapter / NotificationCenterAXAdapter
  → 后台线程内 AX 只读遍历 + NotificationCardParser
  → POST /notifications/capture
  → ArkEvent 校验 → EventStore 去重持久化
  → POST /notifications/summary（时间与应用筛选）
  → 共享推理锁 + 本机 Ollama + 无工具摘要
  → 摘要、覆盖范围、源事件
```

聊天 Skill 使用同一采集器：`notifications.capture` 原生 prepare 只生成说明，用户确认后才读取；RunService 保存事件后只向模型回传计数。`notifications.query` 通过 PythonExecutor 查询同一数据库。聊天中的查询结果遵循现有任务日志与对话存储机制；独立摘要页面不写长期记忆或聊天记录。

统一事件字段：

| 字段 | 用途 |
| --- | --- |
| schema_version | 当前 `1.0` |
| kind | 当前 `notification.received`；保留 `application.state_changed` 类型供未来适配器使用 |
| adapter | 来源适配器，如 `macos.notification-center.ax` |
| source_app / source_bundle_id | 原始应用名与可选 bundle ID；未知来源不猜测 |
| source_id | 可选上游稳定 ID；通用 AX 角色标识不得作为消息 ID |
| title / body | 可读取通知内容 |
| occurred_at / observed_at | 可选接收时间 / 必填采集时间 |
| time_precision / time_label | exact、approximate、unknown，以及原始时间标签 |
| id | 存储层生成的去重摘要；不是 macOS 消息 ID |

通知数据库是 runtime 目录内 `notifications.sqlite3`（支持 `ARK_RUNTIME_DIR`），文件权限 0600。30 天窗口之外的记录不提供查询，在后续写入时清理；不为清理数据启动常驻任务。清空使用 SQLite secure_delete，系统备份、既有聊天历史不在清空范围内。

所有 HTTP 路由继承 Ark 的本地 bearer 校验和浏览器 Origin 拒绝策略；Hermes 的受限 token 不能访问这些路由。技能禁用时拒绝采集、查询与摘要；清空入口仍可使用。

独立摘要固定使用 `127.0.0.1:11434`，禁用环境代理，不继承 OLLAMA_HOST；发送通知前检查 `/api/show`，拒绝远端/云模型或无法确认的元数据。模型名称复用 `ARK_MAIN_MODEL` / Ark 当前模型。摘要客户端没有工具，也不调用记忆写入。单个摘要在 840 秒内完成，模型错误不回传可能包含通知内容的异常体；已采集数据保留供重试。

## 扩展

为其他社交应用实现 `ApplicationEventAdapter` 并返回相同事件，独立处理其 AX 布局和时间语义。模型和存储不需认识应用名称。当前未实现独立微信会话采集或应用状态变化检测。

未来常驻阶段可增设 AXObserver / NSWorkspace 通知驱动的采集调度，必须另外设计可见的监听开关、应用范围、暂停与退出、授权撤销、丢失/恢复边界；本次没有启用这些行为。不能把 AXObserver 的界面变化通知直接当成新消息，需在适配器中确认并去重。

## 验证

自动测试：

```bash
PYTHONPATH=backend:. backend/.venv/bin/python -m unittest discover -s backend/tests
swift test --package-path frontend --scratch-path /private/tmp/ark-notification-tests -j 2
backend/.venv/bin/python scripts/notification_summary_smoke_test.py
```

smoke test 只把脚本内的合成通知发给本机模型，不读真实通知。单元测试覆盖来源隔离、时间边界、未知时间、幂等去重、清理、技能禁用、模型失败保留数据、云模型拒绝、分批覆盖、通知分组和桌面组件排除。

实机验收清单（需授权后执行，目前尚未全部通过）：

1. 微信收到一条有已知内容/时间的通知；通知预览开启，展开通知后手动采集，核对来源、标题、正文和时间精度。
2. 微信多个会话的折叠/展开分组、另一社交应用同时来消息；确认各条不跨应用混淆，不将分组整体当多条完整历史。
3. 再次采集验证重复处理；使用跨午夜、自定义时区、边界时间筛选，核对相对时间估计误差。
4. 清除系统通知后重采集，确认无法补回未保存通知；隐藏预览和未知时间须明确显示限制。
5. 拒绝/撤销辅助功能、原生宿主断开、Ollama 离线、关闭 Skill；确认报错与已有记录保留行为。
6. 页面打开后不点击采集，检查没有新增记录；结束 Ark 后无采集进程或登录项。

本次验证记录：后端全套 65 项（3 项既有跳过）；Swift 测试与构建通过；合成通知已成功调用本机 `qwen3.5:9b-mlx`。当前通知中心实机观察仅获取了天气组件窗口，真实微信通知采集及各 macOS 布局仍待上述验收。
