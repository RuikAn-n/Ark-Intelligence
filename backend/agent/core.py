import ollama

from memory.manager import MemoryManager
from memory.retriever import MemoryRetriever
from memory.writer import MemoryWriter
from memory.consolidator import MemoryConsolidator
from agent.memory_trigger import MemoryTrigger

class ArkAgent:

    def __init__(self):

        self.model = "qwen3.5:9b-mlx"

        self.memory = MemoryManager()

        self.memory_retriever = MemoryRetriever()

        self.memory_writer = MemoryWriter()

        self.conversation = []

        self.consolidator = MemoryConsolidator()

    
    def chat(self, message, background_tasks=None): 
        # 获取长期记忆
        memory_context = self.memory_retriever.retrieve(message)
        

        # 自动检测记忆指令
        if message.startswith("记住"):

            memory_content = message.replace(
                 "记住",
                 ""
            ).strip()

            if not memory_content:
                return "请告诉我需要记住的内容。"
            saved = self.memory.remember(
                memory_content,
                source="explicit",
            )

            if saved:
                return f"好的，我已经记住：{memory_content}"
            return "这条内容与已有记忆重复，我没有重复保存。"
        response = ollama.chat(
            model=self.model,
            messages=[
                {
    "role": "system",
    "content": f"""
你是 Ark Intelligence。

你的身份：
- 你是用户的个人AI助手。
- 你运行在用户的 MacBook Pro 本地环境中。
- 你通过 Ollama 调用 qwen3.5:9b-mlx 模型。
- 你不是网页端通义千问助手。

以下是长期记忆：

{memory_context}

回答要求：
- 根据长期记忆保持对用户的连续理解。
- 如果记忆中存在用户信息，可以自然地使用。
- 不要编造不存在的记忆。
- 不要向用户暴露内部记忆系统的实现细节。
"""
    },
                {
                    "role": "user",
                    "content": message
                }
            ]
        )
        if background_tasks:

            background_tasks.add_task(
            self._write_memory,
            message
        )


        answer = response["message"]["content"]
        self.conversation.append({
            "role": "user",
            "content": message
        })

        self.conversation.append({
            "role": "assistant",
            "content": answer
        })
        return answer

    def end_session(self):

        if not self.conversation:
            return None

        memories = self.memory.recall_all()

        result = self.consolidator.consolidate(
            self.conversation,
            memories
        )

        self.memory.apply_consolidation(result)

        self.conversation = []

        return result

    def _write_memory(self, message):

        import time

        start = time.time()

        print("[MemoryWriter] started")

        try:
            if not MemoryTrigger.should_check(message):
                print("[MemoryWriter] skipped by trigger")
                return

            memory_result = self.memory_writer.analyze(message)

            print(
                "[MemoryWriter] result:",
                memory_result
            )

            if memory_result.get("save"):

                self.memory.remember(
                    memory_result["content"],
                    memory_result["category"],
                    memory_type=memory_result["memory_type"],
                    source="inferred",
                )

                print("[MemoryWriter] memory saved")

            else:

                print("[MemoryWriter] skipped")

        except Exception as e:

            print(
                "[MemoryWriter] ERROR:",
                repr(e)
            )

        print(
            "[MemoryWriter] finished:",
            round(time.time() - start, 2),
            "seconds"
        )