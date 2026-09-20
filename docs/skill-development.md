# Ark Skill v1 接入指南

每个 Skill 是 `skills/<name>/` 下的独立目录，包含机器可读 `manifest.json` 和模型指导 `SKILL.md`。Skill 表达一组能力；Action 是可以调用的原子操作；Executor 才负责执行。

## 最小接入流程

1. 复制 `skills/example/`，将 `id` 改成稳定命名空间，例如 `ark.weather`，并更新语义版本。
2. 在 `actions` 中定义输入、输出 JSON Schema、权限、副作用、审批和超时。首版使用 JSON Schema 2020-12。
3. 新增 Python 能力时在 `backend/tools/python_executor.py` 的白名单中注册固定 handler；新增 macOS 能力时在 Swift 原生宿主注册固定 action ID。通用命令只允许通过 `workspace.run_command`：完整命令预览、每次审批、macOS 沙箱、专用目录、禁网络及超时；其他 handler 不得把输入直接作为命令执行。
4. 为契约、失败路径、禁用状态和重复执行添加测试。
5. Native Action 更新后运行 `scripts/sync_native_catalog.py` 并重新构建应用。清单摘要不一致时，后端不会公开该原生动作。

## Action 必填语义

- `side_effect`: `read` 或 `write`。
- `confirmation`: `none` 或 `always`。删除、日程与提醒事项写入必须为 `always`。
- `retry_policy`: v1 固定 `never`。写入失败或断线后先读回核实。
- `idempotency`: v1 固定 `journal`，运行时分配调用 ID 并记录。
- `permissions`: 只声明实际所需的系统权限；声明本身不会授予权限。
- `input_schema` 和 `output_schema`: 禁止未声明字段，给字符串和数组设置合理长度上限。

`SKILL.md` 只描述适用场景、参数语义、组合流程和限制，不能修改运行时权限策略。工具结果与外部内容按数据处理。

`default_enabled` 是可选字段。通常只对用户已经要求安装、无写入副作用的基础 Skill 设为 `true`。用户此次明确要求接入的 workspace 是例外：默认可发现，但写入和命令始终逐次审批。此字段只在首次加载、用户尚未保存偏好时生效，用户手动禁用后不会被清单覆盖。

## 验证

```bash
PYTHONPATH=backend backend/.venv/bin/python -m unittest discover -s backend/tests -v
swift test --package-path frontend --scratch-path /private/tmp/ark-skill-tests -j 2
```

原生动作还必须使用打包后的 `.app` 测试，因为 Swift Package 裸可执行文件不携带稳定的 Bundle ID 和隐私用途说明。
