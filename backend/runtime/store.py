"""Small, durable execution journal, separate from long-term memory."""
import json
import sqlite3
from contextlib import contextmanager
from pathlib import Path

TERMINAL = {'succeeded', 'failed', 'cancelled', 'interrupted', 'result_unknown'}

class Store:
    def __init__(self, path):
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        with self.connection() as db:
            db.executescript('''
              PRAGMA journal_mode=WAL;
              CREATE TABLE IF NOT EXISTS sessions(id TEXT PRIMARY KEY, messages TEXT NOT NULL);
              CREATE TABLE IF NOT EXISTS runs(id TEXT PRIMARY KEY, session_id TEXT, status TEXT, data TEXT);
              CREATE TABLE IF NOT EXISTS events(id INTEGER PRIMARY KEY AUTOINCREMENT, run_id TEXT, data TEXT);
              CREATE INDEX IF NOT EXISTS events_run ON events(run_id,id);
              CREATE TABLE IF NOT EXISTS settings(id TEXT PRIMARY KEY, enabled INTEGER NOT NULL);
              CREATE TABLE IF NOT EXISTS calls(id TEXT PRIMARY KEY, run_id TEXT, data TEXT);
              PRAGMA user_version=1;
            ''')
            rows = db.execute("SELECT id,data FROM runs WHERE status NOT IN ('succeeded','failed','cancelled','interrupted','result_unknown')").fetchall()
            for row in rows:
                data = json.loads(row['data'])
                data.update(status='interrupted', error='服务已重启；已发送的写操作不得重放，请核实原始目标。', pending=None)
                db.execute('UPDATE runs SET status=?,data=? WHERE id=?', ('interrupted',json.dumps(data),row['id']))
                db.execute('INSERT INTO events(run_id,data) VALUES(?,?)',(row['id'],json.dumps({'event':'error','error':data['error']})))
        self.path.chmod(0o600)

    def connect(self):
        db = sqlite3.connect(self.path, timeout=5)
        db.row_factory = sqlite3.Row
        return db

    @contextmanager
    def connection(self):
        db = self.connect()
        try:
            with db:
                yield db
        finally:
            db.close()

    def enabled(self, id):
        value=self.setting(id)
        return bool(value) if value is not None else False

    def setting(self, id):
        with self.connection() as db:
            row=db.execute('SELECT enabled FROM settings WHERE id=?',(id,)).fetchone()
        return bool(row['enabled']) if row else None

    def set_enabled(self, id, enabled):
        with self.connection() as db: db.execute('INSERT OR REPLACE INTO settings VALUES(?,?)',(id,int(enabled)))

    def save_run(self, run):
        with self.connection() as db:
            db.execute('INSERT OR REPLACE INTO runs VALUES(?,?,?,?)',(run['id'],run['session_id'],run['status'],json.dumps(run,ensure_ascii=False)))

    def get_run(self, id):
        with self.connection() as db: row=db.execute('SELECT data FROM runs WHERE id=?',(id,)).fetchone()
        return json.loads(row['data']) if row else None

    def list_runs(self, session_id=None, active_only=False, limit=50):
        clauses=[]; values=[]
        if session_id:
            clauses.append('session_id=?'); values.append(session_id)
        if active_only:
            clauses.append("status NOT IN ('succeeded','failed','cancelled','interrupted','result_unknown')")
        where=(' WHERE '+' AND '.join(clauses)) if clauses else ''
        values.append(max(1,min(int(limit),200)))
        with self.connection() as db:
            rows=db.execute(f'SELECT data FROM runs{where} ORDER BY rowid DESC LIMIT ?',values).fetchall()
        return [json.loads(row['data']) for row in rows]

    def event(self, run_id, event):
        with self.connection() as db:
            cur=db.execute('INSERT INTO events(run_id,data) VALUES(?,?)',(run_id,json.dumps(event,ensure_ascii=False)))
            return cur.lastrowid

    def events(self, run_id, after=0):
        with self.connection() as db:
            rows=db.execute('SELECT id,data FROM events WHERE run_id=? AND id>? ORDER BY id LIMIT 100',(run_id,after)).fetchall()
        return [dict(json.loads(r['data']),event_id=r['id'],run_id=run_id) for r in rows]

    def messages(self, session_id):
        with self.connection() as db: row=db.execute('SELECT messages FROM sessions WHERE id=?',(session_id,)).fetchone()
        return json.loads(row['messages']) if row else []

    def save_messages(self, session_id, messages):
        with self.connection() as db: db.execute('INSERT OR REPLACE INTO sessions VALUES(?,?)',(session_id,json.dumps(messages,ensure_ascii=False)))

    def append_messages(self, session_id, messages, initial_messages=None, max_messages=20):
        """Append without losing messages when background runs finish out of order."""
        with self.connection() as db:
            db.execute('BEGIN IMMEDIATE')
            row=db.execute('SELECT messages FROM sessions WHERE id=?',(session_id,)).fetchone()
            current=json.loads(row['messages']) if row else list(initial_messages or [])
            current.extend(messages)
            current=current[-max_messages:]
            db.execute('INSERT OR REPLACE INTO sessions VALUES(?,?)',(session_id,json.dumps(current,ensure_ascii=False)))
        return current

    def call(self, call_id, run_id, data):
        with self.connection() as db: db.execute('INSERT OR REPLACE INTO calls VALUES(?,?,?)',(call_id,run_id,json.dumps(data,ensure_ascii=False)))

    def calls(self, run_id):
        with self.connection() as db:
            rows=db.execute('SELECT data FROM calls WHERE run_id=? ORDER BY rowid',(run_id,)).fetchall()
        return [json.loads(row['data']) for row in rows]
