import json
import ollama

from memory.database import get_memories_with_category


class MemoryRetriever:

    def __init__(self):

        self.model = "qwen3.5:0.8b-mlx"
        self.schema = {
            "type": "array",
            "items": {"type": "integer"},
            "maxItems": 8,
        }


    def retrieve(self, message):

        memories = get_memories_with_category()

        if not memories:
            return "暂无长期记忆。"


        memory_items = []

        for memory_id, content, category, created_at in memories:

            memory_items.append({
                "id": memory_id,
                "content": content,
                "category": category,
                "created_at": created_at
            })


        memory_text = json.dumps(
            memory_items,
            ensure_ascii=False
        )


        response = ollama.chat(
            model=self.model,
            think=False,
            format=self.schema,
            messages=[
                {
                    "role": "system",
                    "content": """
你是 Ark Intelligence 的记忆检索模块。

你的任务是根据用户当前消息，
从提供的长期记忆中选择与当前对话最相关的记忆。

规则：

1. 只选择真正相关的记忆。
2. 不要创造新的记忆。
3. 不要修改记忆内容。
4. 可以选择 0 条或多条。
5. 最多选择 8 条。
6. 只输出JSON数组。

输出格式：

[
    0,
    3,
    5
]

数字代表记忆的id。
"""
                },
                {
                    "role": "user",
                    "content": f"""
当前用户消息：

{message}

长期记忆：

{memory_text}
"""
                }
            ]
        )


        raw = response["message"]["content"]

        try:
            selected_ids = json.loads(raw)
            if (
                not isinstance(selected_ids, list)
                or len(selected_ids) > 8
                or any(type(item) is not int for item in selected_ids)
            ):
                raise ValueError("invalid retrieval result")
        except (json.JSONDecodeError, ValueError, TypeError):
            return "暂无相关长期记忆。"


        selected_memories = []

        for item in memory_items:

            if item["id"] in selected_ids:

                selected_memories.append(
                    f"- [{item['category']}] {item['content']}"
                )


        if not selected_memories:

            return "暂无相关长期记忆。"


        return "\n".join(
            selected_memories
        )