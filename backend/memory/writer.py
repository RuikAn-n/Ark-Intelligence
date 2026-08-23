import json
import re

import ollama


MEMORY_SCHEMA = {
    "type": "object",
    "properties": {
        "save": {
            "type": "boolean"
        },
        "category": {
            "type": "string",
            "enum": [
                "general",
                "preference",
                "project",
                "goal"
            ]
        },
        "memory_type": {
            "type": "string",
            "enum": [
                "profile",
                "preference",
                "project",
                "goal",
                "state",
                "event",
                "fact"
            ]
        },
        "content": {
            "type": "string"
        }
    },
    "required": [
        "save",
        "category",
        "memory_type",
        "content"
    ]
}


class MemoryWriter:

    def __init__(self):
        self.model = "qwen3.5:0.8b-mlx"

    def _build_messages(self, message):

        system_prompt = """
你是 Ark Intelligence 的长期记忆写入模块。

你的任务是判断用户消息是否包含值得长期保存的信息。

应该保存：
- 用户身份信息
- 用户长期偏好
- 用户正在进行的长期项目
- 用户长期目标
- 对未来对话有帮助的重要事实

不要保存：
- 普通问候
- 一次性问题
- 临时任务
- 普通知识问答

请严格按照指定 JSON Schema 输出。

规则：

1. 必须包含 save、category、memory_type、content 四个字段。
2. save 必须是 true 或 false。
3. category 只能是：
   - general
   - preference
   - project
   - goal
4. content 必须是用户原话中的最小事实片段，尽量逐字摘录。
5. memory_type 必须准确反映记忆生命周期：profile/profile事实、preference偏好、
   project项目、goal目标、state可被新信息覆盖的当前状态、event一次性事件、fact普通事实。
   category 只能使用前面列出的四个值，个人身份信息也必须使用 category=general。
6. 不得补充、推测、总结或扩写用户没有表达的信息。
7. 如果 save=false，content 必须为空字符串。
8. 不要输出 Markdown。
9. 不要输出解释文字。

示例：
用户：我叫安睿康。
输出：{"save":true,"category":"general","memory_type":"profile","content":"我叫安睿康"}

用户：今天天气不错，帮我写一句问候。
输出：{"save":false,"category":"general","memory_type":"fact","content":""}
"""

        return [
            {
                "role": "system",
                "content": system_prompt
            },
            {
                "role": "user",
                "content": message
            }
        ]

    def _clean_json(self, raw):

        if not raw:
            return ""

        raw = raw.strip()

        # 处理 ```json ... ``` 或 ``` ... ```
        if raw.startswith("```"):

            raw = re.sub(
                r"^```(?:json)?\s*",
                "",
                raw,
                flags=re.IGNORECASE
            )

            raw = re.sub(
                r"\s*```$",
                "",
                raw
            )

            raw = raw.strip()

        return raw

    def _parse_result(self, raw):

        cleaned = self._clean_json(raw)

        if not cleaned:
            raise ValueError("MemoryWriter returned empty output")

        result = json.loads(cleaned)
        if not isinstance(result, dict):
            raise TypeError("MemoryWriter output must be an object")
        required = {"save", "category", "memory_type", "content"}
        if set(result) != required:
            raise ValueError("MemoryWriter output has invalid fields")
        if type(result["save"]) is not bool:
            raise TypeError("save must be boolean")
        if result["category"] == "profile":
            result["category"] = "general"
        if result["category"] not in {
            "general", "preference", "project", "goal"
        }:
            raise ValueError("category is invalid")
        if result["memory_type"] not in {
            "profile", "preference", "project", "goal",
            "state", "event", "fact"
        }:
            raise ValueError("memory_type is invalid")
        if not isinstance(result["content"], str):
            raise TypeError("content must be string")
        if result["save"] and not result["content"].strip():
            raise ValueError("saved content cannot be empty")
        if not result["save"]:
            result["content"] = ""
        return result

    def analyze(self, message):

        messages = self._build_messages(message)

        # 第一次调用
        response = ollama.chat(
            model=self.model,
            think=False,
            format=MEMORY_SCHEMA,
            messages=messages
        )

        raw = response["message"]["content"]

        print(
            "[MemoryWriter] raw:",
            repr(raw)
        )

        # 优先直接解析
        try:

            result = self._parse_result(raw)

            print(
                "[MemoryWriter] result:",
                result
            )

            return result

        except (json.JSONDecodeError, ValueError, TypeError) as e:

            print(
                "[MemoryWriter] parse failed:",
                repr(e)
            )

        # 第二次调用（用来兜底）：保留完整任务上下文
        print("[MemoryWriter] retrying...")

        response = ollama.chat(
            model=self.model,
            think=False,
            format=MEMORY_SCHEMA,
            messages=messages
        )

        raw = response["message"]["content"]

        print(
            "[MemoryWriter] retry raw:",
            repr(raw)
        )

        try:

            result = self._parse_result(raw)

            return result

        except (json.JSONDecodeError, ValueError, TypeError) as e:

            print(
                "[MemoryWriter] retry failed:",
                repr(e)
            )

            raise RuntimeError("MemoryWriter failed after retry") from e