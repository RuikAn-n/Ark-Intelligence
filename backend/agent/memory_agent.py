import json
import ollama


class MemoryAgent:


    def __init__(self):

        self.model = "qwen3.5:9b-mlx"


    def analyze(self, message):

        response = ollama.chat(
            model=self.model,
            messages=[
                {
                    "role": "system",
                    "content": """
你是一个记忆判断模块。

判断用户输入是否值得长期保存。

需要保存：
- 用户身份信息
- 长期偏好
- 项目信息
- 长期目标

不要保存：
- 临时问题
- 普通聊天
- 一次性任务

只输出JSON：

{
 "save": true,
 "category": "project/preference/general",
 "content": "需要保存的信息"
}
"""
                },
                {
                    "role": "user",
                    "content": message
                }
            ]
        )


        return json.loads(
            response["message"]["content"]
        )