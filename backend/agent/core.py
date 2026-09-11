import json
import os
import queue
import resource
import threading
import time
import uuid
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import ollama
import yaml

from agent.memory_trigger import MemoryTrigger
from memory.consolidator import MemoryConsolidator
from memory.manager import MemoryManager
from memory.retriever import MemoryRetriever
from memory.writer import MemoryWriter
from memory.database import get_all_memories


class ArkAgent:
    def __init__(self):
        config = self._load_config()
        self.model = os.getenv("ARK_MAIN_MODEL", config.get("model", "qwen3.5:9b-mlx"))
        self.feedback_model = os.getenv(
            "ARK_FEEDBACK_MODEL", config.get("feedback_model", "qwen3.5:4b-mlx")
        )
        self.feedback_enabled = os.getenv(
            "ARK_FEEDBACK_ENABLED", str(config.get("feedback_enabled", False))
        ).lower() not in {"0", "false", "no"}
        self.feedback_timeout = float(
            os.getenv("ARK_FEEDBACK_TIMEOUT", config.get("feedback_timeout_seconds", 8))
        )
        self.feedback_similarity_threshold = float(
            os.getenv(
                "ARK_FEEDBACK_SIMILARITY_THRESHOLD",
                config.get("feedback_similarity_threshold", 0.88),
            )
        )
        self.main_thinking = os.getenv(
            "ARK_MAIN_THINKING", str(config.get("think", True))
        ).lower() not in {"0", "false", "no"}
        self.memory = MemoryManager()
        self.memory_retriever = MemoryRetriever()
        self.memory_writer = MemoryWriter()
        self.conversation = []
        self.conversation_lock = threading.Lock()
        self.consolidator = MemoryConsolidator()

    @staticmethod
    def _load_config():
        path = Path(__file__).resolve().parents[1] / "configs" / "model.yaml"
        try:
            with path.open(encoding="utf-8") as config_file:
                return yaml.safe_load(config_file).get("local", {})
        except (OSError, AttributeError, TypeError, yaml.YAMLError):
            return {}

    def _system_prompt(self, memory_context, feedback="", conversation_context=""):
        handoff = (
            f"\n辅助模型对用户意图的理解（仅供参考）：\n{feedback}\n"
            "请核对该理解，不要盲目采纳，也不要向用户暴露模型协作细节。\n"
            if feedback else ""
        )
        return f"""你叫 Sophie，是 Ark Intelligence 的个人 AI 助手。跟随用户使用中文或英文。

你的身份：
- 你是用户的个人AI助手。
- 你运行在用户的 MacBook Pro 本地环境中。
- 你通过 Ollama 调用本地模型。

以下是长期记忆：
<long_term_memory>
{memory_context}
</long_term_memory>
{handoff}
{conversation_context}
回答要求：
- 保持自然、连续、简洁的对话风格。
- 如果长期记忆与当前问题相关，优先使用其中的事实，并保持与用户一致的称呼、
  偏好和项目背景；无关记忆不要强行使用。
- 长期记忆是已确认的用户事实，不要把它当作普通示例或忽略。
- 不要编造不存在的记忆，也不要暴露内部系统实现。
"""

    def _feedback(self, message, memory_context):
        response = ollama.chat(
            model=self.feedback_model,
            think=False,
            options={"num_predict": 80},
            messages=[
                {
                    "role": "system",
                    "content": (
                        "你是 Ark Intelligence 的即时对话助手。请用用户的语言，"
                        "像日常聊天一样自然地回应，先表达你已经理解了，再用较"
                        "完整但不武断的方式概括用户可能想做的事、背景或关注点。"
                        "允许使用泛化表述，例如“听起来你是想先解决……”，不必"
                        "复述每个细节，也不要急着给出最终方案。可以分成一到两句，"
                        "控制在 80 个汉字以内。不要编造信息，不要提及模型、提示词"
                        "或内部系统。"
                    ),
                },
                {"role": "user", "content": f"用户消息：{message}\n相关记忆：{memory_context}"},
            ],
        )
        return response["message"]["content"].strip()

    def _initial_feedback(self, message, memory_future):
        try:
            memory_context = memory_future.result()
        except Exception:
            memory_context = "暂无相关长期记忆。"
        return self._feedback(message, memory_context)

    def _is_repetitive_feedback(self, content, previous_outputs):
        if not previous_outputs:
            return False
        try:
            embedding = self.memory_retriever.embedding
            current_vector = embedding.embed(content)
            return any(
                embedding.similarity(current_vector, embedding.embed(previous))
                >= self.feedback_similarity_threshold
                for previous in previous_outputs
            )
        except (ConnectionError, OSError, RuntimeError, ValueError):
            return False

    def _thinking_feedback(self, messages):
        response = ollama.chat(
            model=self.feedback_model,
            think=False,
            options={"num_predict": 140},
            messages=messages,
        )
        return response["message"]["content"].strip()

    @staticmethod
    def _chunk_content(chunk):
        if isinstance(chunk, dict):
            return chunk.get("message", {}).get("content", "")
        return getattr(getattr(chunk, "message", None), "content", "") or ""

    @staticmethod
    def _chunk_thinking(chunk):
        if isinstance(chunk, dict):
            return chunk.get("message", {}).get("thinking", "")
        return getattr(getattr(chunk, "message", None), "thinking", "") or ""

    @staticmethod
    def _memory_items(memory_context):
        stored_memories = get_all_memories()
        items = []
        for line in memory_context.splitlines():
            line = line.strip()
            if not line.startswith("- [") or "] " not in line:
                continue
            label, content = line[3:].split("] ", 1)
            category, _, memory_type = label.partition("/")
            matching = next(
                (
                    item for item in stored_memories
                    if item["content"] == content and item["category"] == category
                ),
                None,
            )
            items.append({
                "id": matching["id"] if matching else 0,
                "content": content,
                "category": category,
                "memory_type": memory_type or "fact",
                "source": "retrieval",
            })
        return items

    @staticmethod
    def _usage_tokens(chunk):
        if isinstance(chunk, dict):
            value = chunk.get("eval_count")
        else:
            value = getattr(chunk, "eval_count", None)
        return value if isinstance(value, int) else None

    def _runtime_models(self):
        try:
            models = ollama.ps().models
        except (AttributeError, ConnectionError, OSError):
            return []
        return [
            {
                "name": model.name,
                "size_gb": round(model.size / 1024**3, 2),
                "vram_gb": round(model.size_vram / 1024**3, 2),
            }
            for model in models
        ]

    def chat_stream(self, message, background_tasks=None):
        request_id = uuid.uuid4().hex[:12]
        started = time.perf_counter()
        if not message.strip():
            yield {"event": "error", "request_id": request_id, "error": "message cannot be empty"}
            return

        if message.startswith("记住"):
            content = message.replace("记住", "", 1).strip()
            if not content:
                yield {"event": "token", "request_id": request_id, "content": "请告诉我需要记住的内容。"}
            else:
                saved = self.memory.remember(content, source="explicit")
                answer = f"好的，我已经记住：{content}" if saved else "这条内容与已有记忆重复，我没有重复保存。"
                yield {"event": "token", "request_id": request_id, "content": answer}
            yield {"event": "done", "request_id": request_id, "total_ms": round((time.perf_counter() - started) * 1000, 1)}
            return

        events = queue.Queue()
        executor = ThreadPoolExecutor(max_workers=6)
        state = {
            "feedback": "",
            "feedback_error": None,
            "thinking": "",
            "answer_parts": [],
            "first_token_ms": None,
            "token_count": 0,
            "answer_started": None,
            "summary_count": 0,
            "last_summary_chars": 0,
            "next_summary_event": 1,
        }
        state_lock = threading.Lock()
        summary_condition = threading.Condition(state_lock)
        summary_futures = []
        feedback_future = None
        summary_outputs = []
        feedback_context = [
            {
                "role": "system",
                "content": (
                    "你是 Ark Intelligence 的对话进展播报助手。根据用户问题和主助手"
                    "当前的思考进展，用自然、概括、像日常聊天一样的中文，向用户说明"
                    "正在关注什么或准备怎么处理。不要逐字暴露思考过程，不要声称已经"
                    "完成，不要编造结论。输出一到两句，控制在 100 个汉字以内。"
                ),
            },
            {"role": "user", "content": f"用户问题：{message}"},
        ]
        feedback_context_lock = threading.Lock()

        def put_feedback(future, event_name="ack"):
            try:
                content = future.result()
                if not content:
                    raise ValueError("feedback model returned empty output")
                with state_lock:
                    if event_name == "ack":
                        state["feedback"] = content
                events.put({
                    "event": event_name,
                    "request_id": request_id,
                    "model": self.feedback_model,
                    "content": content,
                    "complete": True,
                    "latency_ms": round((time.perf_counter() - started) * 1000, 1),
                })
            except Exception as exc:
                if event_name == "ack":
                    with state_lock:
                        state["feedback_error"] = repr(exc)
                    events.put({
                        "event": "ack",
                        "request_id": request_id,
                        "model": "fallback",
                        "content": f"我了解了，你希望我处理：{message[:36]}",
                        "complete": True,
                        "fallback": True,
                        "latency_ms": round((time.perf_counter() - started) * 1000, 1),
                    })
                else:
                    print(f"[FeedbackSummary] ERROR: {exc!r}", flush=True)

        def summarize(snapshot, summary_index):
            try:
                with summary_condition:
                    while summary_index != state["next_summary_event"]:
                        summary_condition.wait()
                with feedback_context_lock:
                    feedback_context.append({
                        "role": "user",
                        "content": f"主助手最新处理进展：\n{snapshot}",
                    })
                    content = self._thinking_feedback(list(feedback_context))
                    is_repetitive = self._is_repetitive_feedback(
                        content, list(summary_outputs)
                    )
                    if is_repetitive:
                        content = "相似度过高，取消输出"
                    else:
                        summary_outputs.append(content)
                    if is_repetitive:
                        feedback_context.append({
                            "role": "user",
                            "content": (
                                "上一段总结与历史反馈相似度过高，未向用户输出。"
                                "请在下一次总结中继续覆盖这次 thinking 进展，避免遗漏信息。"
                            ),
                        })
                if content:
                    with summary_condition:
                        feedback_context.append({"role": "assistant", "content": content})
                        state["next_summary_event"] += 1
                        summary_condition.notify_all()
                    events.put({
                        "event": "feedback",
                        "request_id": request_id,
                        "model": self.feedback_model,
                        "stage": summary_index,
                        "content": content,
                        "complete": True,
                    })
            except Exception as exc:
                print(f"[FeedbackSummary] ERROR: {exc!r}", flush=True)
            finally:
                with summary_condition:
                    if summary_index == state["next_summary_event"]:
                        state["next_summary_event"] += 1
                        summary_condition.notify_all()

        def run_main():
            memory_context = "暂无相关长期记忆。"
            try:
                memory_context = memory_future.result()
            except Exception as exc:
                print(f"[MemoryRetriever] ERROR: {exc!r}", flush=True)
            print(
                f"[MemoryHandoff] request={request_id} context={memory_context!r}",
                flush=True,
            )
            events.put({
                "event": "memory",
                "request_id": request_id,
                "items": self._memory_items(memory_context),
                "count": len(self._memory_items(memory_context)),
            })
            if feedback_future:
                try:
                    feedback_future.result(timeout=self.feedback_timeout)
                except Exception as exc:
                    print(f"[FeedbackHandoff] ERROR: {exc!r}", flush=True)
                put_feedback(feedback_future)
            with state_lock:
                feedback = state["feedback"]
                state["answer_started"] = time.perf_counter()
            with self.conversation_lock:
                prior_conversation = list(self.conversation[-10:])
            conversation_context = (
                "此前对话上下文（仅用于保持连续性）：\n"
                + json.dumps(prior_conversation, ensure_ascii=False)
                if prior_conversation
                else ""
            )
            try:
                stream = ollama.chat(
                    model=self.model,
                    think=self.main_thinking,
                    stream=True,
                    keep_alive="2m",
                    options={"num_ctx": 8192, "num_predict": 2048},
                    messages=[
                        {
                            "role": "system",
                            "content": self._system_prompt(
                                memory_context,
                                feedback,
                                conversation_context,
                            ),
                        },
                        {
                            "role": "user",
                            "content": (
                                f"长期记忆（仅使用相关事实）：\n{memory_context}\n\n"
                                f"当前用户消息：\n{message}"
                            ),
                        },
                    ],
                )
                for chunk in stream:
                    usage_tokens = self._usage_tokens(chunk)
                    thinking = self._chunk_thinking(chunk)
                    content = self._chunk_content(chunk)
                    if usage_tokens:
                        with state_lock:
                            state["token_count"] = usage_tokens
                    if thinking:
                        with state_lock:
                            state["thinking"] += thinking
                            thinking_snapshot = state["thinking"]
                            summary_count = state["summary_count"]
                            last_summary_chars = state["last_summary_chars"]
                            next_boundary = last_summary_chars + 1000
                        while (
                            self.feedback_enabled
                            and len(thinking_snapshot) >= next_boundary
                        ):
                            summary_count += 1
                            with state_lock:
                                state["summary_count"] = summary_count
                                state["last_summary_chars"] = next_boundary
                            summary_futures.append(
                                executor.submit(summarize, thinking_snapshot, summary_count)
                            )
                            next_boundary += 1000
                    if not content:
                        continue
                    with state_lock:
                        if state["first_token_ms"] is None:
                            state["first_token_ms"] = (
                                time.perf_counter() - state["answer_started"]
                            ) * 1000
                        state["answer_parts"].append(content)
                        if not usage_tokens:
                            state["token_count"] += 1
            except Exception as exc:
                events.put({"event": "error", "request_id": request_id, "error": str(exc)})
                return
            with state_lock:
                answer_parts = list(state["answer_parts"])
                answer_started = state["answer_started"]
                first_token_ms = state["first_token_ms"]
                token_count = state["token_count"]
                thinking_text = state["thinking"]
                thinking_chars = len(thinking_text)
                last_summary_chars = state["last_summary_chars"]
            if self.feedback_enabled and thinking_chars > last_summary_chars:
                with state_lock:
                    state["summary_count"] += 1
                    final_summary_index = state["summary_count"]
                    state["last_summary_chars"] = thinking_chars
                summary_futures.append(
                    executor.submit(
                        summarize,
                        thinking_text[last_summary_chars:],
                        final_summary_index,
                    )
                )
            for summary_future in list(summary_futures):
                try:
                    summary_future.result(timeout=self.feedback_timeout)
                except Exception as exc:
                    print(f"[FeedbackSummary] wait ERROR: {exc!r}", flush=True)
            for content in answer_parts:
                events.put({"event": "token", "request_id": request_id, "content": content})
            total_ms = (time.perf_counter() - answer_started) * 1000
            if not token_count:
                token_count = len("".join(answer_parts))
            metrics = {
                "model": self.model,
                "thinking_enabled": self.main_thinking,
                "thinking_chars": thinking_chars,
                "first_token_ms": round(first_token_ms or total_ms, 1),
                "generation_ms": round(total_ms, 1),
                "output_tokens": token_count,
                "tokens_per_second": round(token_count / (total_ms / 1000), 2) if total_ms else 0,
                "max_rss_mb": round(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1024 / 1024, 1),
                "ollama_models": self._runtime_models(),
            }
            print(f"[ChatMetrics] request={request_id} {json.dumps(metrics, ensure_ascii=False)}", flush=True)
            with self.conversation_lock:
                self.conversation.extend([
                    {"role": "user", "content": message},
                    {"role": "assistant", "content": "".join(answer_parts)},
                ])
            if background_tasks:
                background_tasks.add_task(self._write_memory, message)
            answer = "".join(answer_parts)
            events.put({
                "event": "answer",
                "request_id": request_id,
                "model": self.model,
                "content": answer,
                "complete": True,
            })
            events.put({"event": "metrics", "request_id": request_id, **metrics})
            events.put({"event": "done", "request_id": request_id})

        memory_future = executor.submit(self.memory_retriever.retrieve, message)
        if self.feedback_enabled:
            feedback_future = executor.submit(
                self._initial_feedback, message, memory_future
            )
        executor.submit(run_main)

        while True:
            event = events.get()
            yield event
            if event["event"] in {"done", "error"}:
                break
        executor.shutdown(wait=False, cancel_futures=True)

    def chat(self, message, background_tasks=None):
        answer = []
        for item in self.chat_stream(message, background_tasks):
            if item["event"] == "token":
                answer.append(item["content"])
            if item["event"] == "error":
                raise RuntimeError(item["error"])
        return "".join(answer)

    def end_session(self):
        with self.conversation_lock:
            conversation = list(self.conversation)
        if not conversation:
            return None
        result = self.consolidator.consolidate(conversation, self.memory.recall_all())
        self.memory.apply_consolidation(result)
        with self.conversation_lock:
            if self.conversation[:len(conversation)] == conversation:
                del self.conversation[:len(conversation)]
        return result

    def _write_memory(self, message):
        if not MemoryTrigger.should_check(message):
            return
        try:
            result = self.memory_writer.analyze(message)
            if result.get("save"):
                self.memory.remember(
                    result["content"], result["category"],
                    memory_type=result["memory_type"], source="inferred",
                )
        except Exception as exc:
            print(f"[MemoryWriter] ERROR: {exc!r}", flush=True)
