from memory.embedding import MemoryEmbedding
from memory.database import (
    save_memory,
    get_memories,
    get_memories_with_category,
    update_memory,
    delete_memory,
    save_embedding,
    get_embedding,
    get_memories_with_embeddings,
)


class MemoryManager:

    DUPLICATE_THRESHOLD = 0.90
    NEAR_DUPLICATE_THRESHOLD = 0.72

    def __init__(self):
        self.embedding = MemoryEmbedding()

    def remember(
        self,
        content,
        category="general",
        source="inferred",
        confidence=1.0,
        importance=0.5,
    ):
        content = content.strip()
        vector = self.embedding.embed(content)
        candidates = get_memories_with_embeddings()
        best = None
        for item in candidates:
            if item["vector"] is None or item["model"] != self.embedding.model:
                continue
            score = self.embedding.similarity(vector, item["vector"])
            if best is None or score > best[0]:
                best = (score, item)

        if best and best[0] >= self.DUPLICATE_THRESHOLD:
            return False

        memory_id = save_memory(
            content,
            category,
            source,
            confidence,
            importance,
        )
        if memory_id is None:
            return False
        save_embedding(memory_id, self.embedding.model, vector)
        return True

    def reindex_embeddings(self):
        for item in get_memories_with_embeddings():
            if item["vector"] is None or item["model"] != self.embedding.model:
                vector = self.embedding.embed(item["content"])
                save_embedding(item["id"], self.embedding.model, vector)


    def recall(self):

        return get_memories()


    def recall_all(self):

        return get_memories_with_category()
    def update(
        self,
        memory_id,
        content,
        category="general"
    ):
        update_memory(
            memory_id,
            content,
            category
        )
        save_embedding(
            memory_id,
            self.embedding.model,
            self.embedding.embed(content)
        )


    def delete(self, memory_id):
        delete_memory(memory_id)
    def apply_consolidation(self, result):

        # 新增记忆
        for item in result.get("add", []):

            self.remember(
                item["content"],
                item.get("category", "general")
            )

        # 修改记忆
        for item in result.get("update", []):

            self.update(
                item["id"],
                item["content"],
                item.get("category", "general")
            )

        # 删除记忆
        for memory_id in result.get("delete", []):
            self.delete(memory_id)
        #合并记忆
        for item in result.get("merge", []):
            self.merge(
                item["source_ids"],
                item["content"],
                item.get("category", "general")
            )
    def merge(
    self,
    source_ids,
    content,
    category="general"
):
        result = self.remember(
            content,
            category
        )
        if result:
            for memory_id in source_ids:
                self.delete(memory_id)
        return result