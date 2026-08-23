# Ark Intelligence macOS 前端开发计划

## 1. 项目目标

为 Ark Intelligence 本地 AI 助手开发一个基于 **Swift + SwiftUI** 的 macOS 原生前端。

本阶段**只开发前端，不修改现有后端逻辑**。

前端需要围绕以下核心模块构建：

1. 主对话
2. 记忆可视化
3. 语音对话预留
4. 记忆集中管理
5. 对话记录管理
6. Skill 管理

当前后端已经完成：

* 基本对话能力
* 4B 模型总结/分析能力
* 9B 模型主要回答能力
* Memory Agent / Memory Writer
* Memory Retriever
* SQLite 记忆存储
* 记忆调取逻辑

当前暂未完成：

* 语音模型
* Skill 系统
* 后端聊天记录持久化

因此本阶段前端必须为这些功能预留接口，但**不得为了适配前端而擅自修改后端**。

---

# 2. 开发原则

## 2.1 技术栈

使用：

* Swift
* SwiftUI
* Xcode
* macOS App
* MVVM 架构
* Swift Concurrency（async/await）
* Observable / Observation
* NavigationSplitView
* TabView
* List
* ScrollView
* LazyVStack
* Sheet / Popover

尽可能使用 Apple 原生组件，不引入不必要的第三方 UI 框架。

---

# 3. 总体界面架构

建议采用 macOS 原生的侧边栏 + 内容区结构。

```text
Ark Intelligence
│
├── 对话
│   ├── 主对话
│   └── 语音对话
│
├── 记忆
│   ├── 记忆概览
│   └── 记忆管理
│
├── 历史
│   └── 对话记录
│
└── Skills
    └── Skill 管理
```

推荐主布局：

```text
┌──────────────────────────────────────────────┐
│ Ark Intelligence                             │
├───────────────┬──────────────────────────────┤
│               │                              │
│  对话         │                              │
│  ├ 主对话     │                              │
│  └ 语音       │       当前页面内容            │
│               │                              │
│  记忆         │                              │
│  ├ 记忆概览   │                              │
│  └ 记忆管理   │                              │
│               │                              │
│  历史         │                              │
│  └ 对话记录   │                              │
│               │                              │
│  Skills       │                              │
│  └ Skill管理  │                              │
│               │                              │
└───────────────┴──────────────────────────────┘
```

优先使用：

```swift
NavigationSplitView
```

实现 macOS 原生侧边栏体验。

---

# 4. 页面一：主对话界面

## 4.1 页面目标

这是整个应用的核心界面。

需要同时表现：

1. 用户输入
2. 4B 模型总结/分析
3. 9B 模型最终回答
4. 当前回答过程中调用的记忆
5. 后续可扩展 Skill 调用状态

---

## 4.2 页面布局

建议：

```text
┌──────────────────────────────────────────┐
│                 对话                      │
├──────────────────────────────────────────┤
│                                          │
│ 用户                                      │
│ ┌──────────────────────────────────────┐ │
│ │ 最近输入的问题                       │ │
│ └──────────────────────────────────────┘ │
│                                          │
│ 4B 模型总结                               │
│ ┌──────────────────────────────────────┐ │
│ │ 用户意图总结                         │ │
│ │ 上下文分析                           │ │
│ └──────────────────────────────────────┘ │
│                                          │
│ 记忆                                       │
│ ┌──────────────────────────────────────┐ │
│ │ Memory A    Memory B    Memory C     │ │
│ └──────────────────────────────────────┘ │
│                                          │
│ 9B 模型                                   │
│ ┌──────────────────────────────────────┐ │
│ │ 最终回答内容                         │ │
│ │                                      │ │
│ │                                      │ │
│ └──────────────────────────────────────┘ │
│                                          │
├──────────────────────────────────────────┤
│ 输入框                         [发送]     │
└──────────────────────────────────────────┘
```

---

# 5. 对话数据结构

前端创建统一的数据模型。

例如：

```swift
struct ChatMessage: Identifiable {
    let id: UUID
    let role: MessageRole
    let content: String
    let timestamp: Date
    let modelInfo: ModelInfo?
}
```

角色：

```swift
enum MessageRole {
    case user
    case summarizer
    case assistant
    case system
}
```

模型信息：

```swift
struct ModelInfo {
    let modelName: String
    let modelType: ModelType
}
```

模型类型：

```swift
enum ModelType {
    case summarizer4B
    case assistant9B
}
```

---

# 6. 4B 模型显示

4B 模型输出不应该和 9B 模型回答完全混在一起。

视觉上应该明确区分：

```text
4B Summary
```

或者：

```text
意图分析
```

建议使用折叠区域：

```text
▾ 4B 模型分析

用户希望查询……
当前上下文……
相关任务……
```

这样可以让用户决定是否查看模型内部分析信息。

注意：

这里展示的是**后端已经提供给前端的总结结果**。

不要要求后端新增字段，除非当前 API 完全无法提供该数据。

如果目前 API 没有返回 4B 总结：

前端先使用：

```swift
summary: String?
```

预留。

默认：

```swift
nil
```

UI 不显示。

---

# 7. 9B 模型回答

9B 模型作为主要回答区域。

要求：

* Markdown 显示
* 支持段落
* 支持代码
* 支持列表
* 支持未来图片/文件附件
* 支持流式输出预留

建议：

```swift
MarkdownTextView
```

但第一阶段可以使用 SwiftUI 原生 Text + Markdown。

后续可以替换成更完整的 Markdown renderer。

---

# 8. 记忆调用可视化

在每条 9B 回答附近增加：

```text
调用记忆 3 条
```

点击后展开：

```text
相关记忆

● Project
正在开发 Ark Intelligence

● Preference
计划使用 SwiftUI 开发 Mac 客户端

● Goal
希望打造开箱即用的 AI 助手
```

不同来源的记忆必须能够使用不同视觉颜色进行区分。

例如：

```swift
enum MemorySource {
    case retrieval
    case semantic
    case keyword
    case manual
    case system
}
```

颜色仅作为视觉分类，不要把颜色逻辑写死在 View 内。

推荐：

```swift
MemorySourceStyle
```

统一管理。

---

# 9. 页面二：记忆显示界面

这个页面用于：

> 查看当前一次对话过程中调取了哪些记忆。

与“记忆管理”不同。

记忆管理负责：

> 管理数据库中所有记忆。

记忆显示负责：

> 展示当前对话实际调用了哪些记忆。

---

## 9.1 页面布局

```text
┌──────────────────────────────────────┐
│ 记忆                                  │
├──────────────────────────────────────┤
│ 当前对话调用的记忆                    │
│                                      │
│ [Project]                            │
│ 正在开发 Ark Intelligence             │
│                                      │
│ [Preference]                         │
│ 使用 SwiftUI 开发 macOS 应用          │
│                                      │
│ [Goal]                               │
│ 希望项目能够开源                      │
│                                      │
└──────────────────────────────────────┘
```

---

# 10. 记忆颜色系统

不要直接使用：

```swift
Color.blue
Color.green
```

散落在代码中。

创建统一颜色系统：

```swift
enum MemoryCategory {
    case project
    case preference
    case goal
    case general
}
```

然后：

```swift
MemoryCategoryStyle.color
```

统一管理。

第一版只需要视觉区分，不要求固定具体颜色。

---

# 11. 页面三：语音对话

语音模块当前没有后端。

因此第一阶段：

**只做 UI，不接入真实语音模型。**

页面：

```text
┌──────────────────────────────────────┐
│ 语音对话                              │
│                                      │
│                                      │
│              ○                       │
│          开始语音对话                 │
│                                      │
│      语音模型尚未连接                 │
│                                      │
└──────────────────────────────────────┘
```

建议预留状态：

```swift
enum VoiceState {
    case idle
    case listening
    case processing
    case speaking
    case unavailable
}
```

以及：

```swift
protocol VoiceService {
    func startListening()
    func stopListening()
    func speak(_ text: String)
}
```

第一阶段使用：

```swift
MockVoiceService
```

而不是修改后端。

未来接入：

* Speech to Text
* Local Voice Model
* TTS
* Wake Word

都可以复用该接口。

---

# 12. 页面四：记忆集中管理

这是整个应用的第二个核心页面。

功能：

* 查看所有记忆
* 搜索
* 分类
* 修改
* 新增
* 软删除
* 完全删除
* 查看详细信息

---

# 13. 记忆管理布局

建议：

```text
┌──────────────────────────────────────────────┐
│ 记忆管理                                     │
├────────────┬─────────────────────────────────┤
│ 分类       │ 搜索                            │
│            │                                 │
│ 全部       │ 🔍 搜索记忆                     │
│ Project    │                                 │
│ Goal       │ ┌─────────────────────────────┐ │
│ Preference │ │ 记忆内容                    │ │
│ General    │ │                             │ │
│ Deleted    │ └─────────────────────────────┘ │
│            │                                 │
└────────────┴─────────────────────────────────┘
```

采用：

```swift
NavigationSplitView
```

或者内部：

```swift
List + Detail View
```

---

# 14. 记忆管理操作

每条 Memory 支持：

### 查看

点击进入：

```text
Memory Detail
```

包含：

* 内容
* 分类
* 创建时间
* 更新时间
* 来源
* 是否删除
* ID

---

### 修改

使用：

```swift
Sheet
```

或者：

```swift
Form
```

允许修改：

* content
* category

不要在第一版允许随意修改：

* id
* createdAt

---

### 软删除

软删除：

```text
删除
```

只改变：

```swift
isDeleted = true
```

不立即从数据库完全清除。

---

### 完全删除

提供：

```text
永久删除
```

必须增加确认弹窗：

```text
确定永久删除这条记忆吗？

此操作无法恢复。

取消      永久删除
```

---

# 15. 记忆数据结构

前端建立：

```swift
struct MemoryItem: Identifiable {
    let id: UUID
    var content: String
    var category: MemoryCategory
    var source: MemorySource
    let createdAt: Date
    var updatedAt: Date
    var isDeleted: Bool
}
```

如果当前后端字段不同：

**不要为了强行匹配前端而直接修改数据库。**

优先：

```swift
DTO → Domain Model
```

进行转换。

---

# 16. 页面五：对话记录管理

后端目前：

> 尚未保存聊天记录。

因此本页面第一阶段只开发 UI。

---

## 16.1 页面结构

```text
┌─────────────────────────────────────────┐
│ 对话记录                                 │
├─────────────────────────────────────────┤
│                                         │
│ 今天                                     │
│ ┌─────────────────────────────────────┐ │
│ │ 本地 AI 助手架构设计                 │ │
│ │ 12:32                               │ │
│ └─────────────────────────────────────┘ │
│                                         │
│ 昨天                                     │
│ ┌─────────────────────────────────────┐ │
│ │ SwiftUI 开发                         │ │
│ │ 18:42                               │ │
│ └─────────────────────────────────────┘ │
│                                         │
└─────────────────────────────────────────┘
```

按照：

```text
Date ↓
```

排序。

---

# 17. 对话记录模型

建立：

```swift
struct ConversationRecord: Identifiable {
    let id: UUID
    let title: String
    let createdAt: Date
    let updatedAt: Date
    let messageCount: Int
}
```

第一阶段：

```swift
MockConversationRepository
```

负责提供测试数据。

未来后端支持后：

```swift
ConversationRepository
```

直接替换。

UI 层不应该感知具体数据来源。

---

# 18. 页面六：Skill 管理

Skill 系统目前尚未开发。

因此本阶段：

**只开发完整 UI 和数据协议。**

---

# 19. Skill 页面布局

```text
┌──────────────────────────────────────────┐
│ Skills                                   │
├──────────────────────────────────────────┤
│                                          │
│ ┌──────────────────────────────────────┐ │
│ │ 🎵 Music Generator                   │ │
│ │ MIDI 音乐生成                        │ │
│ │                                      │ │
│ │ 状态：已启用                [Toggle] │ │
│ └──────────────────────────────────────┘ │
│                                          │
│ ┌──────────────────────────────────────┐ │
│ │ 📁 File Analyzer                     │ │
│ │ 文件分析                             │ │
│ │                                      │ │
│ │ 状态：未启用                [Toggle] │ │
│ └──────────────────────────────────────┘ │
│                                          │
└──────────────────────────────────────────┘
```

---

# 20. Skill 数据结构

定义：

```swift
struct Skill: Identifiable {
    let id: UUID
    let name: String
    let description: String
    let icon: String
    var isEnabled: Bool
}
```

未来可以扩展：

```swift
struct Skill {
    let id: UUID
    let name: String
    let description: String
    let version: String
    let author: String
    let icon: String
    var isEnabled: Bool
    var status: SkillStatus
}
```

---

# 21. Skill 服务接口

预留：

```swift
protocol SkillRepository {
    func fetchSkills() async throws -> [Skill]
    func enableSkill(_ skill: Skill) async throws
    func disableSkill(_ skill: Skill) async throws
}
```

当前实现：

```swift
MockSkillRepository
```

未来 Skill 后端完成后：

```text
MockSkillRepository
        ↓
SkillRepository
        ↓
真实 Skill API
```

不修改 UI。

---

# 22. 前端整体架构

推荐：

```text
ArkIntelligence/
│
├── App/
│   ├── ArkIntelligenceApp.swift
│   └── AppState.swift
│
├── Core/
│   ├── Models/
│   ├── Services/
│   ├── Repositories/
│   ├── Networking/
│   └── Extensions/
│
├── Features/
│   ├── Chat/
│   │   ├── ChatView.swift
│   │   ├── ChatViewModel.swift
│   │   ├── MessageBubble.swift
│   │   └── ChatInputView.swift
│   │
│   ├── Memory/
│   │   ├── MemoryOverviewView.swift
│   │   ├── MemoryManagerView.swift
│   │   ├── MemoryDetailView.swift
│   │   ├── MemoryEditorView.swift
│   │   └── MemoryViewModel.swift
│   │
│   ├── Voice/
│   │   ├── VoiceConversationView.swift
│   │   └── VoiceViewModel.swift
│   │
│   ├── History/
│   │   ├── ConversationHistoryView.swift
│   │   ├── ConversationDetailView.swift
│   │   └── HistoryViewModel.swift
│   │
│   └── Skills/
│       ├── SkillListView.swift
│       ├── SkillDetailView.swift
│       └── SkillViewModel.swift
│
├── Shared/
│   ├── Components/
│   ├── Styles/
│   ├── Theme/
│   └── Utilities/
│
└── Preview/
    ├── MockData.swift
    └── PreviewContainer.swift
```

---

# 23. MVVM 架构

采用：

```text
View
 ↓
ViewModel
 ↓
Repository / Service
 ↓
API / Local Storage
```

禁止：

```text
View
 ↓
直接访问数据库
```

也禁止：

```text
View
 ↓
直接调用 HTTP API
```

---

# 24. Repository 抽象

建议统一设计：

```swift
protocol ChatRepository
protocol MemoryRepository
protocol ConversationRepository
protocol SkillRepository
protocol VoiceService
```

例如：

```swift
protocol MemoryRepository {
    func fetchMemories() async throws -> [MemoryItem]

    func createMemory(_ memory: MemoryItem) async throws

    func updateMemory(_ memory: MemoryItem) async throws

    func softDeleteMemory(_ memory: MemoryItem) async throws

    func permanentlyDeleteMemory(_ memory: MemoryItem) async throws
}
```

当前：

```text
MemoryRepository
        ↓
Local/API 实现
```

如果后端 API 已经存在，则对接现有 API。

如果后端还没有接口，则：

```text
MemoryRepository
        ↓
MockMemoryRepository
```

---

# 25. 后端修改限制

这是本项目非常重要的约束。

## 不允许

Agent 不得因为前端开发便利：

* 修改 SQLite 数据结构
* 修改 MemoryWriter
* 修改 MemoryRetriever
* 修改 Agent 核心逻辑
* 修改模型调用逻辑
* 修改 FastAPI API 行为
* 修改已有字段含义
* 删除已有 API

---

## 只有以下情况可以考虑后端修改

如果前端需要的数据：

```text
后端完全没有提供
```

并且：

```text
无法通过现有 API 合理获得
```

才允许提出后端 API 扩展需求。

但必须：

1. 停止直接修改
2. 明确告诉用户需要修改后端
3. 说明为什么前端无法独立完成
4. 提出最小化修改方案
5. 等待确认后再修改

---

# 26. Mock 数据策略

在后端功能尚未完成的情况下，所有页面必须能够独立运行。

因此建立：

```swift
MockData.swift
```

包含：

```swift
MockChatData
MockMemoryData
MockConversationData
MockSkillData
```

例如：

```swift
let mockMemories: [MemoryItem] = [...]
```

这样可以直接通过：

```swift
#Preview
```

查看 UI。

---

# 27. Preview 开发要求

所有页面必须支持 Xcode Canvas Preview。

例如：

```swift
#Preview {
    ChatView(
        viewModel: ChatViewModel(
            repository: MockChatRepository()
        )
    )
}
```

要求每个页面至少包含：

### 正常状态

```text
有数据
```

### 空状态

```text
没有数据
```

### 加载状态

```text
Loading
```

### 错误状态

```text
Error
```

---

# 28. 状态管理

建议统一设计：

```swift
enum ViewState<T> {
    case idle
    case loading
    case loaded(T)
    case empty
    case error(Error)
}
```

避免每个 View 自己重复实现状态逻辑。

---

# 29. UI 设计方向

整体风格：

> macOS 原生、简洁、专业、具有 AI 产品感。

不要第一阶段加入大量复杂视觉效果。

优先实现：

* 清晰层级
* 良好的间距
* 原生控件
* 深色/浅色模式
* 可读性
* 键盘操作
* Sidebar
* Hover
* Sheet
* Toolbar

后续再考虑：

* 动画
* 毛玻璃
* 渐变
* 更复杂的 AI 动态效果

---

# 30. 主界面交互细节

主对话需要支持：

```text
Enter
↓
发送
```

同时：

```text
Shift + Enter
↓
换行
```

输入框：

* 多行
* 自动调整高度
* 最大高度限制
* 发送按钮
* 禁止空消息发送

---

# 31. AI 输出状态

预留：

```swift
enum GenerationState {
    case idle
    case thinking
    case streaming
    case completed
    case failed
}
```

UI：

```text
用户发送
   ↓
思考中
   ↓
4B 分析
   ↓
记忆检索
   ↓
9B 回答
   ↓
完成
```

即使后端当前没有完整提供这些状态，也应该在 ViewModel 中设计出来。

---

# 32. 流式回答预留

9B 模型未来可能使用 Streaming API。

因此不要设计成：

```swift
func sendMessage() async -> String
```

唯一接口。

建议抽象：

```swift
func sendMessage(
    _ message: String
) -> AsyncThrowingStream<String, Error>
```

这样未来可以直接实现：

```text
9
94
94B
94B模型
94B模型正在
...
```

逐字/逐段渲染。

第一阶段如果后端没有 Streaming：

可以使用一次性返回模拟。

---

# 33. 记忆调用状态预留

定义：

```swift
struct MemoryRetrievalResult {
    let memories: [MemoryItem]
    let source: MemorySource
}
```

后续可以显示：

```text
Memory Retrieval
↓
3 memories found
```

并允许动画。

---

# 34. 网络层设计

后端目前使用 Python/FastAPI。

Swift 不应该直接把 URL、HTTP 请求写在 ViewModel 中。

统一：

```text
APIClient
```

例如：

```swift
protocol APIClient {
    func request<T: Decodable>(
        _ endpoint: Endpoint
    ) async throws -> T
}
```

然后：

```text
ChatRepository
MemoryRepository
SkillRepository
```

通过 APIClient 通信。

---

# 35. Endpoint 抽象

建立：

```swift
enum APIEndpoint {
    case chat
    case memories
    case memory(id: UUID)
    case conversations
    case skills
}
```

如果当前后端 API 名称不同：

**不要修改后端来配合命名。**

只在 Swift 网络层建立映射。

---

# 36. 第一阶段不实现

以下功能暂时不要实现：

```text
❌ 语音识别模型
❌ TTS
❌ Skill 执行系统
❌ Skill 动态加载
❌ 聊天记录后端保存
❌ 数据库迁移
❌ 用户账户系统
❌ 云同步
❌ iOS/iPadOS 客户端
```

只建立：

```text
UI
Model
ViewModel
Repository Protocol
Mock Repository
API 接口预留
```

---

# 37. 开发顺序

严格按照以下顺序开发。

## Phase 1：项目骨架

完成：

```text
SwiftUI macOS App
↓
NavigationSplitView
↓
Sidebar
↓
页面路由
```

完成所有页面空壳。

---

## Phase 2：设计系统

完成：

* App Theme
* Typography
* Spacing
* Icons
* Memory Category Color
* Card
* Button
* Empty State
* Loading State

---

## Phase 3：主对话

优先级最高。

完成：

```text
ChatView
ChatViewModel
Message Model
Input
Message List
4B Summary
9B Response
Memory Display
Loading State
```

---

## Phase 4：记忆展示

完成：

```text
MemoryOverviewView
MemoryCard
MemoryCategory
MemorySource
Memory filtering
```

---

## Phase 5：记忆管理

完成：

```text
MemoryManager
Memory Detail
Create
Edit
Soft Delete
Permanent Delete
Search
Filter
```

这是当前第二优先级。

---

## Phase 6：对话历史

只做前端：

```text
History
Timeline
Conversation List
Conversation Detail
Empty State
```

使用 Mock 数据。

---

## Phase 7：Skill

完成：

```text
Skill List
Skill Card
Skill Detail
Enable / Disable
MockSkillRepository
```

---

## Phase 8：语音

完成：

```text
Voice UI
Voice State
VoiceService Protocol
MockVoiceService
```

暂时不接模型。

---

# 38. 开发优先级

最终优先级：

```text
P0
主界面
对话
4B
9B
Memory Display

P1
Memory Manager

P2
Conversation History

P2
Skill Manager

P3
Voice UI

P4
动画 / 高级视觉效果
```

---

# 39. 第一版完成标准

当以下全部完成时，认为前端 MVP 完成：

## 主界面

* [ ] 可以输入消息
* [ ] 可以显示用户消息
* [ ] 可以显示 4B 总结
* [ ] 可以显示 9B 回答
* [ ] 可以显示关联记忆
* [ ] 可以显示 Loading
* [ ] 可以显示 Error

## 记忆

* [ ] 可以显示不同分类
* [ ] 可以使用不同颜色区分
* [ ] 可以搜索
* [ ] 可以筛选
* [ ] 可以查看
* [ ] 可以修改
* [ ] 可以软删除
* [ ] 可以永久删除

## 历史

* [ ] 可以显示 Mock 对话记录
* [ ] 可以按照时间排列
* [ ] 可以打开详细对话
* [ ] 后端没有数据时可以显示 Empty State

## Skill

* [ ] 显示 Skill
* [ ] 显示描述
* [ ] 显示状态
* [ ] 可以模拟启用/关闭

## Voice

* [ ] UI 完整
* [ ] 状态完整
* [ ] VoiceService Protocol 完成
* [ ] 不接入真实模型

---

# 40. Agent 执行约束

必须遵守：

### 原则 1

只修改 Swift / SwiftUI 前端相关代码。

### 原则 2

不要主动修改 Python、FastAPI、SQLite、Memory Agent 等后端文件。

### 原则 3

如果必须修改后端：

```text
必须先告诉用户：
1. 修改原因
2. 涉及文件
3. 修改内容
4. 是否可以通过前端 Adapter / Mock 避免
```

未经确认不得执行。

### 原则 4

优先使用 Mock 数据完成 UI，再逐步连接真实 API。

### 原则 5

所有新模块必须采用：

```text
Model
ViewModel
Repository / Service
View
```

分层。

### 原则 6

不要把 API 请求直接写入 SwiftUI View。

### 原则 7

所有页面必须支持：

```text
Light Mode
Dark Mode
Empty State
Loading State
Error State
```

### 原则 8

所有页面必须可以在：

```text
Xcode macOS Simulator / Canvas Preview
```

中运行。

---

# 41. 最终目标架构

最终前端应该形成：

```text
                  Ark Intelligence
                         │
                 ┌───────┴───────┐
                 │   SwiftUI UI   │
                 └───────┬───────┘
                         │
                     ViewModel
                         │
              ┌──────────┼───────────┐
              │          │           │
           ChatRepo   MemoryRepo   SkillRepo
              │          │           │
              └──────────┼───────────┘
                         │
                     APIClient
                         │
                    FastAPI Backend
                         │
       ┌─────────────────┼─────────────────┐
       │                 │                 │
     4B Model          9B Model        Memory System
                                           │
                                         SQLite
```

未来扩展：

```text
VoiceService
Skill System
Streaming
Local Model Control
Apple System Integration
```

都应该在这一架构基础上增加，而不是推翻现有 UI。

---

# 42. Agent 当前第一步任务

不要一次性实现全部功能。

首先完成：

```text
1. 创建 SwiftUI macOS 项目结构
2. 创建 NavigationSplitView
3. 创建 Sidebar
4. 创建所有一级页面
5. 创建 Model
6. 创建 Repository Protocol
7. 创建 Mock Repository
8. 创建 Preview 数据
9. 确保 Xcode 可以正常 Preview
```

完成后再进入：

```text
Chat UI
↓
Memory UI
↓
History
↓
Skills
↓
Voice
```

最终要求：

> 在不修改现有后端的前提下，先得到一个完整、可运行、可 Preview、具有真实 macOS 原生产品结构的 Ark Intelligence 前端。
