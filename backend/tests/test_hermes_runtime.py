import asyncio
import json
import os
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest

from agent.run_service import RunService
from runtime.store import Store
from skills.registry import Registry, SkillError
from tools.hermes import HermesIntegration, Worker, skill_id

ROOT = Path(__file__).resolve().parents[2]
TOOL = {'name': 'terminal', 'description': 'Run a command', 'parameters': {
    'type': 'object', 'properties': {'command': {'type': 'string'}, 'timeout': {'type': 'integer'},
        'background': {'type': 'boolean'}}, 'required': ['command']}}


class FakeWorker:
    def __init__(self): self.requests = []; self.closed = False; self.failure = None
    async def request(self, payload, timeout=90):
        self.requests.append(payload)
        if payload['operation'] == 'catalog':
            return {'skills': [{'name': 'docx', 'description': 'Word documents', 'category': 'productivity'}], 'tools': [TOOL]}
        if payload['operation'] == 'skill':
            return {'success': True, 'name': 'docx', 'content': 'instructions'*1000,
                    'skill_dir': '/skills/docx', 'linked_files': {'scripts': ['scripts/create.py']}}
        return self.failure or {'output': 'ok', 'exit_code': 0}
    async def close(self): self.closed = True


class HermesTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.store = Store(Path(self.temp.name) / 'runs.db')
        self.registry = Registry(ROOT, self.store)
        self.service = RunService(self.store, self.registry, SimpleNamespace(actions=set()))
        self.workers = []
        def factory():
            worker = FakeWorker(); self.workers.append(worker); return worker
        self.hermes = HermesIntegration(ROOT, self.store, factory)
        self.service.hermes = self.registry.hermes = self.hermes
        await self.hermes.refresh()

    async def asyncTearDown(self):
        tasks = list(self.service.tasks.values())
        for task in tasks: task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)
        for key in list(self.hermes.workers): await self.hermes.close(key)
        self.temp.cleanup()

    def create(self, action, args):
        return self.service.create(SimpleNamespace(session_id='test', message='test', history=[],
            current_time='2026-09-20T10:00:00+08:00', timezone='Asia/Shanghai', action_id=action, arguments=args))

    async def wait(self, run, status):
        for _ in range(200):
            state = self.store.get_run(run['id'])
            if state['status'] == status: return state
            await asyncio.sleep(.005)
        self.fail(str(state))

    async def test_catalog_search_pagination_and_disabled_skill(self):
        self.assertEqual(self.hermes.listing()[0]['source'], 'hermes')
        data = await self.hermes.execute('hermes.skills_list', {'query': 'word'}, 'r')
        self.assertEqual(data['total'], 1)
        data = await self.hermes.execute('hermes.skill_view', {'name': 'docx', 'offset': 6000, 'limit': 100}, 'r')
        self.assertEqual(len(data['content']), 100)
        self.assertEqual(data['next_offset'], 6100)
        self.store.set_enabled(skill_id('docx'), False)
        self.assertEqual((await self.hermes.execute('hermes.skills_list', {}, 'r'))['total'], 0)
        with self.assertRaises(SkillError): await self.hermes.prepare('hermes.skill_view', {'name': 'docx'}, 'r')
        await self.hermes.refresh(force=True)
        self.assertFalse(self.hermes.listing()[0]['isEnabled'])

    async def test_execution_waits_for_exact_approval_and_rejection_never_dispatches(self):
        run = self.create('hermes.execute', {'name': 'terminal', 'arguments': {'command': 'pwd'}})
        pending = (await self.wait(run, 'waiting_approval'))['pending']
        self.assertEqual(pending['preview']['arguments'], {'command': 'pwd'})
        self.assertIn('本机账户权限', pending['preview']['execution_scope'])
        self.assertFalse(any(r['operation'] == 'execute' for w in self.workers for r in w.requests))
        with self.assertRaises(SkillError): self.service.approve(run['id'], pending['call_id'], 'wrong', True)
        self.service.approve(run['id'], pending['call_id'], pending['digest'], False)
        await self.wait(run, 'failed')
        self.assertFalse(any(r['operation'] == 'execute' for w in self.workers for r in w.requests))

    async def test_approved_dispatch_is_journaled_once_and_worker_closes(self):
        run = self.create('hermes.execute', {'name': 'terminal', 'arguments': {'command': 'pwd'}})
        task = self.service.tasks[run['id']]
        pending = (await self.wait(run, 'waiting_approval'))['pending']
        self.service.approve(run['id'], pending['call_id'], pending['digest'], True)
        await task
        self.assertEqual(self.store.get_run(run['id'])['status'], 'succeeded')
        self.assertEqual(len(self.store.calls(run['id'])), 1)
        self.assertEqual(sum(r['operation'] == 'execute' for w in self.workers for r in w.requests), 1)
        self.assertTrue(all(w.closed for w in self.workers))

    async def test_unknown_tool_and_invalid_arguments_fail_before_approval(self):
        for args in ({'name': 'delegate_task', 'arguments': {}},
                     {'name': 'terminal', 'arguments': {'code': 'pwd'}},
                     {'name': 'terminal', 'arguments': {'command': 'pwd', 'background': True}}):
            run = self.create('hermes.execute', args)
            await self.wait(run, 'failed')
            self.assertFalse(any(e['event'] == 'approval_required' for e in self.store.events(run['id'])))

    async def test_disable_master_while_waiting_prevents_execution(self):
        run = self.create('hermes.execute', {'name': 'terminal', 'arguments': {'command': 'pwd'}})
        pending = (await self.wait(run, 'waiting_approval'))['pending']
        self.store.set_enabled('ark.hermes', False)
        self.service.approve(run['id'], pending['call_id'], pending['digest'], True)
        await self.wait(run, 'failed')
        self.assertFalse(any(r['operation'] == 'execute' for w in self.workers for r in w.requests))

    async def test_nonzero_and_error_results_are_not_success(self):
        for result in ({'exit_code': 1, 'output': 'failed'}, {'success': False, 'error': 'missing dependency'}):
            self.hermes.worker('r').failure = result
            with self.assertRaises(SkillError): await self.hermes.execute('hermes.execute', {'name': 'terminal', 'arguments': {'command': 'pwd'}}, 'r')

    async def test_native_vision_sends_pixels_to_local_model_without_journaling_base64(self):
        requests = []
        class Client:
            async def chat(inner, **kwargs):
                requests.append(kwargs)
                return SimpleNamespace(message=SimpleNamespace(content='A test image'))
        self.service.client = Client()
        result = await self.service.describe_images({'content':[
            {'type':'text','text':'Describe this test'},
            {'type':'image_url','image_url':{'url':'data:image/png;base64,aGVsbG8='}}]})
        self.assertEqual(requests[0]['messages'][-1]['images'], [b'hello'])
        self.assertEqual(result['analysis'], 'A test image')
        self.assertNotIn('base64', json.dumps(result))
        with self.assertRaises(SkillError):
            await self.service.describe_images({'content':[{'type':'image_url','image_url':{'url':'https://example.com/image'}}]})

    async def test_missing_runtime_degrades_without_breaking_ark_tools(self):
        self.hermes.worker_factory = None
        self.hermes.python = Path('/not-installed/python')
        await self.hermes.refresh(force=True)
        names = {t['function']['name'] for t in self.registry.tools(set())}
        self.assertNotIn('hermes__execute', names)
        self.assertIn('workspace__read_file', names)
        self.assertFalse(next(s for s in self.registry.listing(set(), {}) if s['id'] == 'ark.hermes')['available'])

    async def test_model_loop_discovers_loads_skill_and_reads_attachment(self):
        calls = [('hermes__skills_list', {'query': 'docx'}),
                 ('hermes__skill_view', {'name': 'docx', 'limit': 100}),
                 ('hermes__skill_view', {'name': 'docx', 'file_path': 'scripts/create.py', 'limit': 100})]
        class Client:
            async def chat(inner, **kwargs):
                tool_calls = []
                if calls:
                    name, args = calls.pop(0)
                    tool_calls = [SimpleNamespace(model_dump=lambda **_: {'function': {'name': name, 'arguments': args}})]
                async def stream():
                    yield SimpleNamespace(message=SimpleNamespace(content='' if tool_calls else '已读取技能与脚本。', thinking='', tool_calls=tool_calls))
                return stream()
        self.service.client = Client()
        run = self.create(None, {})
        await self.service.tasks[run['id']]
        self.assertEqual(self.store.get_run(run['id'])['status'], 'succeeded')
        self.assertIn(skill_id('docx'), self.store.get_run(run['id'])['skill_ids'])
        self.assertEqual(len(self.store.calls(run['id'])), 3)


class WorkerTests(unittest.IsolatedAsyncioTestCase):
    async def test_timeout_and_cancel_terminate_worker(self):
        import sys
        worker = Worker([sys.executable, '-c', 'import time; time.sleep(60)'], dict(os.environ), '/private/tmp')
        with self.assertRaises(SkillError) as error:
            await worker.request({'operation': 'execute'}, timeout=.05)
        self.assertEqual(error.exception.code, 'RESULT_UNKNOWN')
        self.assertIsNone(worker.process)
        task = asyncio.create_task(worker.request({'operation': 'catalog'}))
        await asyncio.sleep(.05)
        task.cancel()
        with self.assertRaises(asyncio.CancelledError): await task
        self.assertIsNone(worker.process)


@unittest.skipUnless(os.getenv('ARK_TEST_HERMES') == '1', 'Requires the local Hermes installation')
class InstalledHermesTests(unittest.IsolatedAsyncioTestCase):
    async def test_real_discovery_skill_attachment_and_terminal(self):
        with tempfile.TemporaryDirectory() as directory:
            store = Store(Path(directory) / 'runs.db')
            integration = HermesIntegration(ROOT, store)
            try:
                await integration.refresh()
                self.assertIsNone(integration.error)
                self.assertIn('docx', integration.skills)
                self.assertNotIn('apple-reminders', integration.skills)
                data = await integration.execute('hermes.skill_view', {'name': 'docx'}, 'real')
                self.assertIn('scripts', data['linked_files'])
                data = await integration.execute('hermes.skill_view', {'name': 'docx', 'file_path': 'scripts/docx_create.py'}, 'real')
                self.assertTrue(data['content'])
                for bad in ('../../config.yaml', '/etc/passwd'):
                    with self.assertRaises(SkillError):
                        await integration.execute('hermes.skill_view', {'name': 'docx', 'file_path': bad}, 'real')
                args = {'name': 'terminal', 'arguments': {'command': "printf 'ark-hermes-smoke'", 'timeout': 10}}
                await integration.prepare('hermes.execute', args, 'real')
                result = await integration.execute('hermes.execute', args, 'real')
                self.assertIn('ark-hermes-smoke', json.dumps(result))
            finally: await integration.close('real')
