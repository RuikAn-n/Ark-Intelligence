# Skill 系统测试指南

## 准备

确保 Ollama 已运行且安装 `qwen3.5:9b-mlx`。项目将模型上下文限制为 8K，最多暂存 4 个后台任务，但只允许 1 个 9B 推理占用 GPU。审批等待和 macOS 原生操作不会占住推理槽。进度反馈由轻量状态事件产生，不加载第二个 4B 模型，适配 24GB 统一内存。

终端一启动后端：

```bash
cd /Users/anruikang/Documents/Ark-Intelligence
./scripts/run_backend.sh
```

后端默认监听 `127.0.0.1:8765`。如需临时换端口，后端使用 `ARK_PORT=9001 ./scripts/run_backend.sh`，启动应用时同时设置 `ARK_API_URL=http://127.0.0.1:9001`。

终端二构建并打开应用：

```bash
cd /Users/anruikang/Documents/Ark-Intelligence
./scripts/build_app.sh
open "build/Ark Intelligence.app"
```

进入“Skill 管理”，启用“应用管理”“日历”“提醒事项”。首次使用日历或提醒事项时，macOS 会弹出权限请求。若曾拒绝，请到“系统设置 → 隐私与安全性 → 日历/提醒事项”重新允许 Ark。

## 自动测试

```bash
PYTHONPATH=backend backend/.venv/bin/python -m unittest discover -s backend/tests -v
swift test --package-path frontend --scratch-path /private/tmp/ark-skill-tests -j 2
backend/.venv/bin/python scripts/smoke_test.py
backend/.venv/bin/python scripts/model_smoke_test.py
backend/.venv/bin/python scripts/web_search_smoke_test.py
```

`smoke_test.py` 只查找 Safari，不打开应用。`model_smoke_test.py` 让 9B 模型调用只读的运行中应用列表；第一次可能需要数秒加载模型。

`web_search_smoke_test.py` 会真实访问互联网：先直接验证搜索提供方，再要求 9B 根据当前时间自行搜索并读取一个公开网页，最后检查回答包含来源链接。测试轮询降为每 0.5 秒一次，避免给本地后端增加无意义负载。

可选的系统操作验收会打开并正常退出计算器：

```bash
backend/.venv/bin/python scripts/application_action_test.py
```

## 手动场景

依次在主对话输入：

1. `查看明天有哪些安排。`
2. `打开计算器。`
3. `明天下午三点提醒我交材料。` 检查预览中的绝对日期和时区，再确认。
4. `把刚创建的交材料提醒改到下午四点。` 检查修改前后，再确认。
5. `退出计算器。`
6. `搜索 Python 官网最近的版本发布信息，读取一个最相关页面后简要总结并附来源。` 检查右侧任务栏依次包含“搜索互联网”和“读取网页”，且回答中的链接可以点击。

后台与流畅性验收：

1. 输入一个需要写入的请求，例如 `明天下午三点提醒我交材料。`。
2. 在操作卡片停留于“等待确认”时，不作确认，立即继续输入 `1+1 等于多少？`。
3. 确认输入框仍可发送，界面显示 2 个后台任务，第二条消息能获得回答。
4. 点击工具栏右侧的任务栏按钮，确认右侧分栏可以独立开关，主对话中不再混入任务卡片。
5. 待确认操作应自动展开任务栏；在第一张任务卡片中展开 Skill 调用序列并确认执行，检查状态按“准备 → 等待确认 → 执行 → 核验 → 完成”更新。
6. 再同时发送 3 条请求，确认每个任务有独立卡片和取消按钮；第 5 个活动任务会被资源上限拒绝。

后端会将运行记录、事件和 Skill 调用序列保存在 `~/Library/Application Support/ArkIntelligence/runtime/runs.sqlite3`。当前对话中最多展示最近 20 个任务和 60 次 Skill 调用。

测试日历写入时建议先在系统日历创建单独的“Ark 测试”日历，并明确告诉助手使用该日历。删除操作只对测试数据进行。

验收时确认：没有启用技能时不会调用；目标重名会先询问；写操作必须出现预览；拒绝后没有变更；执行成功后能在系统应用中读回；应用存在未保存内容时只请求正常退出，不会强制终止。
