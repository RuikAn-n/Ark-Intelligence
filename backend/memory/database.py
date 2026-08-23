import json
import sqlite3
from datetime import datetime, timezone
from pathlib import Path


DB_PATH = Path(__file__).resolve().parent / "memory.db"


def _now():
    return datetime.now(timezone.utc).isoformat()


def _connect():
    DB_PATH.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(DB_PATH, timeout=30)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys = ON")
    conn.execute("PRAGMA busy_timeout = 30000")
    return conn


def init_db():
    with _connect() as conn:
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS memories (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                content TEXT NOT NULL,
                category TEXT NOT NULL DEFAULT 'general',
                source TEXT NOT NULL DEFAULT 'inferred',
                confidence REAL NOT NULL DEFAULT 1.0,
                importance REAL NOT NULL DEFAULT 0.5,
                status TEXT NOT NULL DEFAULT 'active',
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                last_accessed_at TEXT
            )
            """
        )
        columns = {
            row["name"]
            for row in conn.execute("PRAGMA table_info(memories)")
        }
        migrations = {
            "category": "TEXT NOT NULL DEFAULT 'general'",
            "source": "TEXT NOT NULL DEFAULT 'inferred'",
            "confidence": "REAL NOT NULL DEFAULT 1.0",
            "importance": "REAL NOT NULL DEFAULT 0.5",
            "status": "TEXT NOT NULL DEFAULT 'active'",
            "updated_at": "TEXT",
            "last_accessed_at": "TEXT",
        }
        for name, definition in migrations.items():
            if name not in columns:
                conn.execute(
                    f"ALTER TABLE memories ADD COLUMN {name} {definition}"
                )
        conn.execute(
            "UPDATE memories SET updated_at = COALESCE(updated_at, created_at)"
        )
        conn.execute(
            """
            CREATE INDEX IF NOT EXISTS idx_memories_status
            ON memories(status)
            """
        )
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS memory_embeddings (
                memory_id INTEGER PRIMARY KEY,
                model TEXT NOT NULL,
                vector TEXT NOT NULL,
                created_at TEXT NOT NULL,
                FOREIGN KEY(memory_id) REFERENCES memories(id) ON DELETE CASCADE
            )
            """
        )


def save_memory(
    content,
    category="general",
    source="inferred",
    confidence=1.0,
    importance=0.5,
):
    content = content.strip()
    if not content:
        raise ValueError("Memory content cannot be empty")

    now = _now()
    with _connect() as conn:
        duplicate = conn.execute(
            """
            SELECT id FROM memories
            WHERE status = 'active' AND content = ?
            """,
            (content,),
        ).fetchone()
        if duplicate:
            return None
        cursor = conn.execute(
            """
            INSERT INTO memories
            (content, category, source, confidence, importance, status,
             created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, 'active', ?, ?)
            """,
            (
                content,
                category,
                source,
                confidence,
                importance,
                now,
                now,
            ),
        )
        return cursor.lastrowid


def get_memories():
    with _connect() as conn:
        return [
            row["content"]
            for row in conn.execute(
                """
                SELECT content FROM memories
                WHERE status = 'active'
                ORDER BY id
                """
            )
        ]


def get_memories_with_category():
    with _connect() as conn:
        return [
            tuple(row)
            for row in conn.execute(
                """
                SELECT id, content, category, created_at
                FROM memories
                WHERE status = 'active'
                ORDER BY id
                """
            )
        ]


def get_memories_with_embeddings():
    with _connect() as conn:
        rows = conn.execute(
            """
            SELECT m.id, m.content, m.category, m.created_at,
                   e.model, e.vector
            FROM memories AS m
            LEFT JOIN memory_embeddings AS e ON e.memory_id = m.id
            WHERE m.status = 'active'
            ORDER BY m.id
            """
        ).fetchall()
        return [
            {
                "id": row["id"],
                "content": row["content"],
                "category": row["category"],
                "created_at": row["created_at"],
                "model": row["model"],
                "vector": json.loads(row["vector"])
                if row["vector"]
                else None,
            }
            for row in rows
        ]


def update_memory(memory_id, content, category="general"):
    content = content.strip()
    if not content:
        raise ValueError("Memory content cannot be empty")
    with _connect() as conn:
        cursor = conn.execute(
            """
            UPDATE memories
            SET content = ?, category = ?, updated_at = ?
            WHERE id = ? AND status = 'active'
            """,
            (content, category, _now(), memory_id),
        )
        if cursor.rowcount != 1:
            raise ValueError(f"Active memory {memory_id} does not exist")


def delete_memory(memory_id):
    with _connect() as conn:
        conn.execute(
            """
            UPDATE memories SET status = 'deleted', updated_at = ?
            WHERE id = ? AND status = 'active'
            """,
            (_now(), memory_id),
        )


def save_embedding(memory_id, model, vector):
    with _connect() as conn:
        conn.execute(
            """
            INSERT OR REPLACE INTO memory_embeddings
            (memory_id, model, vector, created_at)
            VALUES (?, ?, ?, ?)
            """,
            (memory_id, model, json.dumps(vector), _now()),
        )


def get_embedding(memory_id):
    with _connect() as conn:
        row = conn.execute(
            "SELECT vector FROM memory_embeddings WHERE memory_id = ?",
            (memory_id,),
        ).fetchone()
        return json.loads(row["vector"]) if row else None


init_db()
