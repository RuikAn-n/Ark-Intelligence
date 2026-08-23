import json
import ollama


class MemoryConsolidator:

    def __init__(self):

        self.model = "qwen3.5:9b-mlx"
        self.schema = {
            "type": "object",
            "properties": {
                "add": {"type": "array"},
                "update": {"type": "array"},
                "merge": {"type": "array"},
                "delete": {"type": "array", "items": {"type": "integer"}},
            },
            "required": ["add", "update", "merge", "delete"],
        }

    def consolidate(self, conversation, memories):

        memory_text = json.dumps(
            memories,
            ensure_ascii=False,
            indent=2
        )

        conversation_text = json.dumps(
            conversation,
            ensure_ascii=False,
            indent=2
        )

        system_prompt = """
你是 Ark Intelligence 的长期记忆整理模块。

你的任务是在一段对话结束后，
根据完整对话内容整理长期记忆。

你可以执行四种操作：

1. add
新增一条长期记忆。

2. update
修改已有长期记忆。

3. delete
只建议删除明确失效、错误或由用户明确否定的记忆。
不要因为内容重复、内容不重要、内容暂时无关而删除记忆。

重要原则：
- 不确定是否应该删除时，禁止删除。
- 不要删除用户身份、长期目标、核心项目、长期偏好等高价值记忆。

4. keep
保持已有记忆不变。

规则：

- 只保存对未来长期对话有价值的信息。
- 不要保存一次性问题、临时任务或普通闲聊。
- 不要编造用户没有表达的信息。
- 不要因为措辞变化就重复创建相同事实。
- 如果新信息与已有记忆表达的是同一个事实，优先 update，而不是 add。
- 如果已有记忆已经失效，应 delete。
- 保持记忆简洁、明确。
- content 必须基于用户实际表达。
- 不要把助手自己的回答当作用户事实。

只输出 JSON：

{
    "add": [
        {
            "category": "general",
            "content": "..."
        }
    ],
    "update": [
        {
            "id": 1,
            "category": "general",
            "content": "..."
        }
    ],
    "merge": [
        {
            "source_ids": [2, 3],
            "category": "project",
            "content": "..."
        }
    ],
    "delete": []
}
"""

        response = ollama.chat(
            model=self.model,
            think=False,
            format=self.schema,
            messages=[
                {
                    "role": "system",
                    "content": system_prompt
                },
                {
                    "role": "user",
                    "content": (
                        f"当前对话：\n"
                        f"{conversation_text}\n\n"
                        f"已有长期记忆：\n"
                        f"{memory_text}"
                    )
                }
            ]
        )

        raw = response["message"]["content"]

        print(
            "[MemoryConsolidator] raw:",
            repr(raw)
        )

        return json.loads(raw)