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

本轮没有验证工具调用正确率、多模型调度或长期记忆真实会话准确率。启动时提示可选 tirith 未安装，命令扫描使用模式匹配；无工具测试还出现 Unknown toolsets: omh 提示，插件工具可用性需在后续专项测试核验。不要把这次聊天通过视为全部 OMH 工作流通过。

建议下一轮：在测试目录验证一项只读 OMH 工具调用；再测试“候选记忆→审核→新会话召回→更新/过期”；最后比较本地模型参数与提示词的成功率和延迟。

## 维护

本轮通过源码 editable 安装，开发修改 Python 文件后重启会话；新增 OMH 包文件时可能需要重新安装 editable 包。不要直接运行 `omh update` 破坏固定版本对照，升级时分别选择并记录两个仓库的新提交、重装依赖、重新 setup 和测试。

测试状态与配置都在 `.hermes-lab` 中，现有 Ark 后端环境及记忆数据库保持独立。此目录隔离数据，不是操作系统沙箱；启用 terminal 工具后仍有本机账户权限。
