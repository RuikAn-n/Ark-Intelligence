"""Application-independent events; observation time is never delivery time."""
from contextlib import contextmanager
import hashlib
import json
import sqlite3
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Literal

from pydantic import AwareDatetime, BaseModel, ConfigDict, Field, model_validator


class ArkEvent(BaseModel):
    model_config = ConfigDict(extra='forbid')
    schema_version: Literal['1.0'] = '1.0'
    kind: Literal['notification.received', 'application.state_changed'] = 'notification.received'
    adapter: str = Field(min_length=1, max_length=100)
    source_app: str = Field(min_length=1, max_length=200)
    source_bundle_id: str | None = Field(default=None, max_length=200)
    source_id: str | None = Field(default=None, max_length=500)
    title: str = Field(default='', max_length=1000)
    body: str = Field(default='', max_length=4000)
    observed_at: AwareDatetime
    occurred_at: AwareDatetime | None = None
    time_precision: Literal['exact', 'approximate', 'unknown'] = 'unknown'
    time_label: str | None = Field(default=None, max_length=200)

    @model_validator(mode='after')
    def coherent_time(self):
        if (self.occurred_at is None) != (self.time_precision == 'unknown'):
            raise ValueError('接收时间及其精度不一致')
        if self.occurred_at and self.occurred_at > self.observed_at + timedelta(seconds=60):
            raise ValueError('接收时间不能晚于采集时间')
        if not self.title.strip() and not self.body.strip():
            raise ValueError('事件内容为空')
        return self


class EventRange(BaseModel):
    start: AwareDatetime
    end: AwareDatetime
    source_app: str | None = Field(default=None, max_length=200)

    @model_validator(mode='after')
    def valid_range(self):
        if self.end <= self.start:
            raise ValueError('结束时间必须晚于开始时间')
        if self.end - self.start > timedelta(days=31):
            raise ValueError('单次最多总结 31 天')
        return self


class EventStore:
    retention_days = 30

    def __init__(self, path: Path):
        self.path = path
        path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        with self.connect() as db:
            db.execute('CREATE TABLE IF NOT EXISTS app_events (id TEXT PRIMARY KEY, occurred REAL, observed REAL NOT NULL, source TEXT NOT NULL, data TEXT NOT NULL)')
            db.execute('CREATE INDEX IF NOT EXISTS app_events_time ON app_events(occurred)')
        path.chmod(0o600)

    @contextmanager
    def connect(self):
        db = sqlite3.connect(self.path, timeout=10)
        try:
            with db:
                yield db
        finally:
            db.close()

    def ingest(self, events: list[ArkEvent]):
        inserted = 0
        with self.connect() as db:
            db.execute('DELETE FROM app_events WHERE observed < ?', ((datetime.now(timezone.utc) - timedelta(days=self.retention_days)).timestamp(),))
            for event in events:
                payload = event.model_dump(mode='json')
                # Stable AX IDs identify a card. Without one, dedup is conservative:
                # content + delivery minute (or observation day if time is unknown).
                identity = [event.adapter, event.source_app, event.kind, event.source_id, event.title, event.body]
                if not event.source_id:
                    identity.append(event.occurred_at.astimezone(timezone.utc).isoformat(timespec='minutes') if event.occurred_at else event.observed_at.astimezone(timezone.utc).date().isoformat())
                key = hashlib.sha256(json.dumps(identity, ensure_ascii=False).encode()).hexdigest()
                payload['id'] = key
                inserted += db.execute('INSERT OR IGNORE INTO app_events VALUES(?,?,?,?,?)', (key, event.occurred_at.timestamp() if event.occurred_at else None, event.observed_at.timestamp(), event.source_app, json.dumps(payload, ensure_ascii=False))).rowcount
        return inserted

    def query(self, window: EventRange, limit=500):
        clauses = ['occurred >= ?', 'occurred < ?', 'observed >= ?']
        values = [window.start.timestamp(), window.end.timestamp(), (datetime.now(timezone.utc) - timedelta(days=self.retention_days)).timestamp()]
        if window.source_app:
            clauses.append('source = ?'); values.append(window.source_app)
        where = ' AND '.join(clauses)
        with self.connect() as db:
            count = db.execute(f'SELECT COUNT(*) FROM app_events WHERE {where}', values).fetchone()[0]
            rows = db.execute(f'SELECT data FROM app_events WHERE {where} ORDER BY occurred, id LIMIT ?', [*values, limit]).fetchall()
            unknown = db.execute('SELECT COUNT(*) FROM app_events WHERE occurred IS NULL AND observed >= ? AND observed < ?' + (' AND source = ?' if window.source_app else ''), [max(window.start.timestamp(), values[2]), window.end.timestamp(), *([window.source_app] if window.source_app else [])]).fetchone()[0]
        return {'events': [json.loads(row[0]) for row in rows], 'total': count, 'truncated': count > limit, 'unknown_time_count': unknown, 'verified': True,
                'coverage': '仅包含手动采集且可读取的通知；时间不明的通知未纳入接收时间筛选。相对时间为估计，重复内容可能合并。'}

    def clear(self):
        with self.connect() as db:
            db.execute('PRAGMA secure_delete=ON')
            db.execute('DELETE FROM app_events')
