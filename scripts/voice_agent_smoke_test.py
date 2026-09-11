#!/usr/bin/env python3
"""Exercise the real local LLM with isolated history and only the harmless echo skill."""
import asyncio
import json
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'backend'))
from agent.run_service import RunService
from runtime.store import Store
from skills.registry import Registry


async def main():
    with tempfile.TemporaryDirectory(prefix='sophie-agent-test-') as folder:
        store = Store(Path(folder) / 'runs.sqlite3')
        registry = Registry(ROOT, store)
        for skill in registry.skills:
            store.set_enabled(skill, skill == 'ark.example')
        service = RunService(store, registry, SimpleNamespace(actions=set(), permissions={}))
        results = []
        original_emit = service.emit
        timing = {}
        def measured_emit(run, event, **data):
            if event == 'speech_segment':
                timing.setdefault(run['id'], time.monotonic())
            original_emit(run, event, **data)
        service.emit = measured_emit
        for message in ['你好，简单介绍一下你自己。', 'Please introduce yourself in one short English sentence.', '请调用 example.echo 工具回显 hello，然后简短告诉我结果。']:
            start = time.monotonic()
            run = service.create(SimpleNamespace(session_id='voice-test', message=message, history=[], action_id=None, input_mode='voice', current_time=datetime.now(timezone.utc).isoformat(), timezone='UTC'))
            first = None
            while run['id'] in service.tasks:
                if first is None and any(e['event'] == 'speech_segment' for e in store.events(run['id'])):
                    first = time.monotonic() - start
                await asyncio.sleep(0.05)
            first = timing.get(run['id'], time.monotonic()) - start
            events = store.events(run['id'])
            answer = next((e['content'] for e in events if e['event']=='answer'), None)
            status = store.get_run(run['id'])['status']
            assert status == 'succeeded', events[-3:]
            assert any(e['event'] == 'speech_segment' for e in events)
            if 'example.echo' in message:
                assert any(e['event'] == 'tool_finished' and e.get('action_id') == 'example.echo' for e in events), events
            row = dict(message=message,answer=answer,first_speech_segment_seconds=first,total_seconds=time.monotonic()-start)
            results.append(row)
            print(json.dumps(row,ensure_ascii=False),flush=True)
        out = ROOT / 'build/voice-benchmark/agent-results.json'
        out.parent.mkdir(parents=True,exist_ok=True)
        out.write_text(json.dumps(results,ensure_ascii=False,indent=2))


if __name__ == '__main__': asyncio.run(main())
