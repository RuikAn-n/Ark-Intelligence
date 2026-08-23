import json
import math
import os
from datetime import datetime, timezone
from pathlib import Path

import ollama
import yaml

from memory.database import get_memories_with_embeddings, touch_memory
from memory.embedding import MemoryEmbedding


class MemoryRetriever:
    CANDIDATE_LIMIT = 20
    RESULT_LIMIT = 8
    RELEVANCE_THRESHOLD = 0.30

    def __init__(self):
        self.model = "qwen3.5:0.8b-mlx"
        config = {}
        try:
            config_path = Path(__file__).resolve().parents[1] / "configs" / "model.yaml"
            with config_path.open(encoding="utf-8") as config_file:
                config = yaml.safe_load(config_file).get("local", {})
        except (OSError, AttributeError, TypeError, yaml.YAMLError):
            config = {}
        self.relevance_threshold = float(
            os.getenv(
                "ARK_MEMORY_RELEVANCE_THRESHOLD",
                config.get("memory_relevance_threshold", self.RELEVANCE_THRESHOLD),
            )
        )
        self.embedding = MemoryEmbedding()
        self.schema = {
            "type": "array",
            "items": {"type": "integer"},
            "maxItems": self.RESULT_LIMIT,
        }

    @staticmethod
    def _recency(created_at):
        try:
            created = datetime.fromisoformat(created_at)
            age_days = max(
                0,
                (datetime.now(timezone.utc) - created).total_seconds() / 86400,
            )
            return math.exp(-age_days / 180)
        except (TypeError, ValueError):
            return 0.5

    def retrieve(self, message):
        query_vector = self.embedding.embed(message)
        candidates = []
        for item in get_memories_with_embeddings():
            if item["vector"] is None or item["model"] != self.embedding.model:
                continue
            similarity = self.embedding.similarity(query_vector, item["vector"])
            if any(
                term in message and keyword in item["content"]
                for term in ("名字", "姓名", "叫什么", "称呼")
                for keyword in ("名字", "姓名", "用户名", "我叫", "用户姓名")
            ):
                similarity = min(1.0, similarity + 0.35)
            score = (
                similarity * 0.70
                + item["importance"] * 0.20
                + item["confidence"] * 0.05
                + self._recency(item["created_at"]) * 0.05
            )
            candidates.append((score, similarity, item))

        if not candidates:
            return "暂无长期记忆。"

        candidates.sort(key=lambda value: value[0], reverse=True)
        selected_candidates = candidates[: self.CANDIDATE_LIMIT]
        memory_items = [
            {
                "id": item["id"],
                "content": item["content"],
                "category": item["category"],
                "memory_type": item["memory_type"],
            }
            for _, _, item in selected_candidates
        ]
        response = ollama.chat(
            model=self.model,
            think=False,
            format=self.schema,
            messages=[
                {
                    "role": "system",
                    "content": (
                        "你是长期记忆重排模块。只从候选记忆中选择与当前消息"
                        "直接相关的记忆 ID。无关时输出[]，最多输出8个整数。"
                        "不要创造、修改或解释任何内容，只输出JSON数组。"
                    ),
                },
                {
                    "role": "user",
                    "content": (
                        f"当前消息：\n{message}\n\n候选记忆：\n"
                        f"{json.dumps(memory_items, ensure_ascii=False)}"
                    ),
                },
            ],
        )
        try:
            selected_ids = json.loads(response["message"]["content"])
            if (
                not isinstance(selected_ids, list)
                or len(selected_ids) > self.RESULT_LIMIT
                or any(type(item) is not int for item in selected_ids)
            ):
                raise ValueError("invalid retrieval result")
        except (KeyError, json.JSONDecodeError, ValueError, TypeError):
            selected_ids = []

        selected = [
            item for item in memory_items if item["id"] in selected_ids
        ]
        if not selected:
            selected = [
                item
                for _, similarity, item in selected_candidates
                if similarity >= self.relevance_threshold
            ][: self.RESULT_LIMIT]
        for item in selected:
            touch_memory(item["id"])
        if not selected:
            return "暂无相关长期记忆。"
        return "\n".join(
            f"- [{item['category']}/{item['memory_type']}] {item['content']}"
            for item in selected
        )
