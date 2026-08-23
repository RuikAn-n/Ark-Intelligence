import ollama


class MemoryEmbedding:

    def __init__(self):

        self.model = "qwen3-embedding:0.6b"

    def embed(self, text):
        text = text.strip()
        if not text:
            raise ValueError("Cannot embed empty text")
        response = ollama.embed(model=self.model, input=text)
        embeddings = response.get("embeddings")
        if not embeddings or not embeddings[0]:
            raise RuntimeError("Embedding model returned no vector")
        return embeddings[0]

    def similarity(self, vector_a, vector_b):

        dot_product = sum(
            a * b
            for a, b in zip(vector_a, vector_b)
        )

        norm_a = sum(
            a * a
            for a in vector_a
        ) ** 0.5

        norm_b = sum(
            b * b
            for b in vector_b
        ) ** 0.5

        if norm_a == 0 or norm_b == 0:
            return 0.0

        return dot_product / (norm_a * norm_b)