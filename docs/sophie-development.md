# Sophie 语音开发记录

目标：macOS 本地中英文语音对话，与文字共用会话、长期记忆、Skill 和操作审批。唤醒词为 Hey Sophie，唤醒后播放本地提示音。

## 技术决策

- ASR：Qwen3-ASR-0.6B-8bit；TTS：Qwen3-TTS-12Hz-0.6B-CustomVoice-8bit；运行库 MLX-Audio。首先验证 0.6B 组合，再按实测决定是否升级。
- KWS：sherpa-onnx 中英 Zipformer 3M；VAD：Silero ONNX，通过 sherpa-onnx 执行。
- 独立 `.voice-venv` 和 loopback 语音服务，不更换聊天后端环境。模型在项目 `.voice-models` 中，不提交权重和个人音频。
- ASR 使用 VAD 分段识别，不将文件转写的 token streaming 宣称为麦克风增量识别。只有最终转写进入共同聊天入口。
- 工具循环的规划文本不播报。语音模式把工具规划与最终回答生成分开，后者禁止工具调用并按语义短句推送。
- 停播不等于取消技能。审批仍在任务卡片中完成。
- 本轮只建立和验证 0.6B 可运行基线；CosyVoice、1.7B 及 MiniCPM-o 的主观质量比较需要相同录音集，不能凭公开宣传数字选胜者。

## 顺序及验收

1. 安装隔离环境、下载固定模型、记录版本/校验摘要；跑合成→识别基线。
2. 增加 Sophie 双语身份、显式记忆解析、语音回答分句与事件；测试工具规划不泄漏、失败不报成功。
3. macOS 原生采集/播放和字幕，文字/语音共用 ChatViewModel；连接状态和模型缺失可见。
4. 唤醒、提示音、连续对话、静音超时、语音打断，处理回声和失效播放队列。
5. Python/Swift 回归、录音基准与手动麦克风验收。

体验目标（不是已经测得的结果）：热启动普通问答首个有效语音 P50≤1.5s/P95≤3s；检测后提示音≤150ms；打断停播≤300ms；TTS RTF<1。唤醒召回≥95%、8小时背景音误触发≤1次需要专门录音集和长时实测。

## 当前交付状态（2026-09-09）

已完成可运行首版：模型与依赖锁定、独立语音服务、Swift 麦克风采集/重采样、Voice Processing 回声处理、PCM 流式播放、120ms 本地提示音、Hey Sophie 唤醒、人声端点检测、连续会话、打断停播、短句字幕、双语显式记忆、共用会话和 Skill 审批。

语音服务仅监听 loopback，使用与聊天后端相同的本地令牌；原始录音只在内存中保留，模型加载后离线运行。最多一个语音连接、16 个待合成短句，MLX 推理由单线程执行器串行处理。用户插话时清空旧音频与未播放队列；旧任务仍在任务面板中，停止朗读不会自动重做或撤销写操作。连接关闭会使旧回答的播报回调失效。

等待模型或审批期间延长待机时间至最多 5 分钟；普通静音 30 秒返回待唤醒。单次录音最长约 25 秒。设备切换时显示重连提示；睡眠时关闭麦克风，唤醒后手动重开。说“再见”或“先这样”返回待唤醒；会话整理使用“结束并整理记忆”按钮。

## 启动和试用

开发机已完成安装和模型下载。新环境首次运行：

```bash
./scripts/setup_voice.sh
```

分别在两个终端启动（端口已占用时不要重复启动）：

```bash
./scripts/run_backend.sh
```

```bash
./scripts/run_voice.sh
```

构建应用：`./scripts/build_app.sh`，打开 `build/Ark Intelligence.app`，进入“语音对话”。点击“开启语音”，首次允许 macOS 麦克风权限，等待模型加载和预热完成，然后说“Hey Sophie”。提示音后可直接说中文或英文；也可使用“直接说话”跳过唤醒词。

测试示例：

1. “Hey Sophie，你叫什么名字？”
2. “Please tell me your name in English.”
3. “记住，我喜欢简短的回答。”然后在主对话询问“我喜欢什么样的回答？”
4. “Remember that I prefer tea.” 然后询问饮品偏好。
5. 启用日历 Skill 后查询今天的日程；涉及写操作时核对右侧任务预览并点击确认。
6. Sophie 播放时插话，确认旧语音停止，任务卡片仍保留实际执行状态。

`ARK_VOICE_URL` 可为应用配置语音服务地址；`ARK_VOICE_PORT` 为服务配置端口。默认 `http://127.0.0.1:8766`。聊天地址仍使用 `ARK_API_URL`。仅使用受信任的本地地址。

## 已完成验证

- 25 项聊天后端测试、8 项语音状态测试、8 项 Swift 测试通过。
- 已构建并签名应用；已检查 Sophie 页面。
- 实机连接修复：VoiceProcessingIO 的输入输出使用相同 I/O 格式，24kHz TTS 在混音器中转换，解决 `-10875 / client-side input and output formats do not match`。录音 tap 在非 MainActor 类型中构造，播放完成回调明确为 Sendable，解决实时音频线程上的 Swift executor 断言退出。新增后台 tap 重采样测试。实际开启麦克风后界面已进入“说 Hey Sophie 唤醒”，WebSocket 保持连接。
- 音频初始化失败现在单独显示设备错误，不再误报为“语音服务未连接”。
- 真实 WebSocket 录音测试通过：唤醒 → VAD → ASR；“Hey Sophie, tell me about the weather.” 被提交为 “Tell me about the weather.”；合成音频和打断确认均返回。
- 真实本地 9B 模型能以 Sophie 身份用中文和英文回答，并成功调用无副作用的 example.echo Skill。
- 合成→识别样本的中文和英文转写一致，测试唤醒样本命中一次。这是合成样本通路测试，不能据此推断真人准确率。

性能原始结果在 `build/voice-benchmark/results.json` 与 `agent-results.json`，测试音频在同目录：

| 测量项 | 结果 | 范围 |
|---|---|---|
| 第一次 TTS 首音 | 3.66 秒 | 冷推理；服务已添加预热 |
| 后续两个 TTS 样本首音 | 0.10–0.13 秒 | 不含 LLM/ASR/端点判断 |
| 后续两个 TTS 样本 RTF | 约 0.285 | 比实时播放快 |
| ASR | 冷样本 0.86 秒；后续 0.11–0.15 秒 | 约 3 秒合成录音 |
| MLX 语音进程峰值 | 约 3.83 GB | 不含 Ollama 和系统占用 |
| 9B 首个可播文本片段 | 2.19–2.63 秒 | 3 个热模型请求，不含语音管线 |

**完整对话 1.5 秒目标尚未达到。** 当前工具规划和最终回答分两次模型调用，主要延迟在 9B 推理；下一轮应测量真实麦克风端到端 P50/P95，并在不泄漏工具规划、不提前宣称执行成功的前提下优化模型调度。

尚未完成真人听感评分、扬声器回声/插话计时、多口音与远场测试、8 小时误唤醒测试、蓝牙设备测试。当前历史保存完整生成回答，尚未持久化每句实际播放完成位置。1.7B/CosyVoice 对照评测也未开展。这些均属于后续体验验收，不应视作已达标。

## 2026-09-10 麦克风输入修复

- 实测根因：VoiceProcessingIO 返回离散三通道，原始 tap 有有效波形，但 AVAudioConverter 默认通道布局转换输出全零。显式 `channelMap = [0]` 选择处理后的麦克风通道。离散三通道正弦测试修复前峰值 0，修复后通过；保留单通道回归。
- 原生页面新增实时音量、输入设备名、无音频/持续静音提示；音量来自服务端实际收到的 PCM，不以 WebSocket 连通代替声音输入成功。认证 `/health` 与 `scripts/voice_status.py` 仅提供帧数、时长、RMS、峰值等聚合诊断，不保存录音。
- 新增输入源菜单：跟随系统、AirPods、MacBook 麦克风等系统可用输入；按设备 UID 保存选择，可刷新列表。只修改本应用音频单元的输入设备，不修改系统默认设备；断开设备明确报错。
- 输入设备异步切换格式时，延迟 500ms 合并通知，在同一引擎上重建 tap/混音器/播放器并保留所选设备；最多恢复三次，避免反复重启。麦克风经静音混音器进入渲染图，不向耳机或扬声器回放本地输入。
- 原生实测：AirPods 修复后服务端 `max_peak` 约 0.049；内置麦克风约 0.50，持续收到有效帧。CoreAudio 日志确认应用输入切换为 BuiltInMicrophoneDevice，输出仍为耳机。原生界面已出现真人测试的识别文本并提交对话任务；识别准确性、唤醒提示音的真人确认、听感和多设备长期稳定性仍需验收。

## 播放期间采集拥堵与唤醒补偿

- 旧实现遇到 `AsyncStream.bufferingNewest` 丢弃一个旧包就 `finish()`，造成播放期间一次短暂背压永久关闭录音。现在保持有界队列、保留最新音频，允许短暂丢旧包；仅转换失败或连接错误结束采集。新增容量 1、连续输入 4 个不同幅值块的回归，验证溢出后仍输出最后一块。
- WebSocket 音频发送使用 `Task.detached`，避免与界面更新、音频播放缓冲调度共用 MainActor。认证诊断增加 `capture_dropped_packets`，区分短暂丢包与采集停止。
- 保留 KWS 快速唤醒，另对待唤醒时 0.35–8 秒的 VAD 语音段做本地 ASR 复核；仅明确位于开头的 Hey Sophie / Hey Sofie / Hey Sophy 或“嗨苏菲”等唤醒形式才唤醒，去除前缀后的指令才交给聊天。普通录音文本不进入聊天或记忆，不持久化；识别结果过期或已经唤醒时忽略。复核需等说完并停顿，延迟高于 KWS，尚无真人成功率统计。
- 新增“测试声音”按钮，便于验证本地 TTS 和播放期间的音量反馈，不产生聊天消息或记忆。
- 实测：用户确认更新后的两轮真实对话均听到回答、未再报采集拥堵；同时原生采集连续超过一分钟、丢帧计数为 0。
- `voice_smoke_test.py --fallback` 在独立临时服务强制关闭 KWS 检测，真实 Qwen3-ASR 仍成功唤醒、移除前缀并转写 weather 指令，TTS 和打断回执均通过。这只证明复核通路有效，不能推断真人唤醒成功率。

## 回归命令

```bash
PYTHONPATH=backend backend/.venv/bin/python -m unittest discover -s backend/tests -v
PYTHONPATH=backend .voice-venv/bin/python -m unittest voice.test_session -v
swift test --package-path frontend --scratch-path /private/tmp/ark-sophie-tests -j 2
.voice-venv/bin/python scripts/voice_benchmark.py
.voice-venv/bin/python scripts/voice_smoke_test.py
.voice-venv/bin/python scripts/voice_smoke_test.py --fallback
backend/.venv/bin/python scripts/voice_agent_smoke_test.py
```

基准脚本不打开麦克风。音频测试创建临时语音服务并在结束时停止；Agent 测试使用独立临时历史，仅启用 echo，不修改日历或个人长期记忆。上游 transformers 在加载 Qwen3-TTS 时会输出模型类型警告，实际加载与生成已通过；临时服务退出有上游 semaphore 清理警告，仍需持续跟踪依赖更新。

## 来源

- https://github.com/QwenLM/Qwen3-ASR
- https://github.com/QwenLM/Qwen3-TTS
- https://github.com/Blaizzy/mlx-audio
- https://github.com/k2-fsa/sherpa-onnx
- https://k2-fsa.github.io/sherpa/onnx/kws/pretrained_models/index.html
- https://github.com/snakers4/silero-vad
