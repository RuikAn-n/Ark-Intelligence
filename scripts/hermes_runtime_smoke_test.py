"""Exercise Ark -> Hermes -> skills/tools in a temporary run store.

Run with PYTHONPATH=backend. Optional model and browser checks need local services.
Only the fixed fixture command/navigation below receives automatic test approval.
"""
import argparse
import asyncio
from datetime import datetime
import json
from pathlib import Path
import shlex
import subprocess
import tempfile
from types import SimpleNamespace
import zipfile

from agent.run_service import RunService
from runtime.store import Store
from skills.registry import Registry

ROOT = Path(__file__).resolve().parents[1]


async def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--model', action='store_true')
    parser.add_argument('--browser', action='store_true')
    parser.add_argument('--vision', action='store_true')
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='ark-hermes-smoke-') as directory:
        folder = Path(directory)
        store = Store(folder / 'runs.db')
        registry = Registry(ROOT, store)
        service = RunService(store, registry, SimpleNamespace(actions=set()))
        await service.hermes.refresh()
        assert not service.hermes.error, service.hermes.error
        print(json.dumps({'skills':len(service.hermes.skills),'tools':sorted(service.hermes.tools)}), flush=True)

        async def run(action, arguments, message='Integration fixture', approval=False):
            request = SimpleNamespace(session_id='smoke', message=message, history=[], action_id=action,
                arguments=arguments, current_time=datetime.now().astimezone().isoformat(), timezone='Asia/Shanghai')
            state = service.create(request)
            task = service.tasks[state['id']]
            for _ in range(1200):
                state = store.get_run(state['id'])
                if task.done(): break
                if state['pending']:
                    pending = state['pending']
                    assert approval and action == 'hermes.execute', 'Unexpected approval request'
                    assert pending['preview']['tool'] == arguments['name']
                    assert pending['preview']['arguments'] == arguments['arguments']
                    service.approve(state['id'], pending['call_id'], pending['digest'], True)
                await asyncio.sleep(.25)
            else:
                await service.cancel(state['id'])
                raise AssertionError('Run timed out')
            await task
            calls = store.calls(state['id'])
            print(json.dumps({'status':state['status'],'actions':[c['action_id'] for c in calls],
                              'answer':store.messages('smoke')[-1]['content'][:1200]}, ensure_ascii=False), flush=True)
            assert state['status'] == 'succeeded', state
            return calls

        if args.model:
            calls = await run(None, {}, '请查找并读取 Hermes 的 docx 技能，告诉我这个技能提供了哪些脚本。只读取技能，不执行命令。')
            assert any(c['action_id'] == 'hermes.skill_view' for c in calls), calls

        loaded = await run('hermes.skill_view', {'name':'docx'})
        skill_dir = Path(loaded[0]['result']['data']['skill_dir'])
        spec = folder / 'spec.json'
        document = folder / 'integration.docx'
        spec.write_text(json.dumps({'blocks':[{'type':'heading','text':'Ark + Hermes integration'},
            {'type':'paragraph','text':'Skill discovered, script executed, output verified.'}]}))
        command = shlex.join([str(service.hermes.python), str(skill_dir / 'scripts/docx_create.py'), str(spec), str(document)])
        await run('hermes.execute', {'name':'terminal','arguments':{'command':command,'timeout':30}}, approval=True)
        with zipfile.ZipFile(document) as archive:
            assert b'output verified' in archive.read('word/document.xml')
        print('DOCX artifact verified', flush=True)

        if args.browser:
            await run('hermes.execute', {'name':'browser_navigate','arguments':{'url':'https://example.com'}}, approval=True)
        if args.vision:
            image = folder / 'red.png'
            subprocess.run([str(service.hermes.python), '-c',
                'from PIL import Image; import sys; Image.new("RGB", (128,128), "red").save(sys.argv[1])', str(image)], check=True)
            calls = await run('hermes.execute', {'name':'vision_analyze','arguments':{
                'image_url':str(image),'question':'What is the main color of this image? Answer with the color name.'}}, approval=True)
            analysis = calls[0]['result']['data']['analysis']
            assert 'red' in analysis.lower() or '红' in analysis, analysis
            print('Local vision pixels and response verified', flush=True)
        print('Hermes integration smoke passed', flush=True)


if __name__ == '__main__': asyncio.run(main())
