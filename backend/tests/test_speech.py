import asyncio
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace

from agent.speech import SentenceBuffer, explicit_memory
from agent.run_service import RunService
from runtime.store import Store


class SpeechTextTests(unittest.TestCase):
    def test_explicit_memory_bilingual(self):
        self.assertEqual(explicit_memory('请记住：我喜欢茶'), '我喜欢茶')
        self.assertEqual(explicit_memory('Please remember that I prefer tea.'), 'I prefer tea.')
        self.assertIsNone(explicit_memory('Do you remember my name?'))

    def test_sentence_fragments_keep_decimal_and_remainder(self):
        buffer = SentenceBuffer()
        self.assertEqual(buffer.add('It costs 3.'), [])
        self.assertEqual(buffer.add('14 yuan. Next'), ['It costs 3.14 yuan.'])
        self.assertEqual(buffer.add(' sentence.', final=True), ['Next sentence.'])
        self.assertEqual(buffer.add('可以。明天见！'), ['可以。', '明天见！'])
        self.assertEqual(buffer.add('你好，明天见。'), ['你好，明天见。'])

    def test_tool_request_can_recall_preferences(self):
        self.assertTrue(RunService.needs_memory('按照我的偏好安排日程'))
        self.assertTrue(RunService.needs_memory('Open my preferred browser'))


class FakeClient:
    def __init__(self): self.requests = []
    async def chat(self, **kwargs):
        self.requests.append(kwargs)
        parts = ['PRIVATE PLANNING'] if 'tools' in kwargs else ['Hello. ', '我是 Sophie。']
        async def stream():
            for part in parts:
                yield SimpleNamespace(message=SimpleNamespace(content=part, thinking='secret', tool_calls=[]))
        return stream()


class SpokenRunTests(unittest.IsolatedAsyncioTestCase):
    async def test_planning_is_not_emitted_and_final_answer_is_shared(self):
        with tempfile.TemporaryDirectory() as folder:
            store = Store(Path(folder) / 'runs.sqlite3')
            client = FakeClient()
            registry = SimpleNamespace(skills={}, tools=lambda _: [])
            service = RunService(store, registry, SimpleNamespace(actions=set()), model_client=client)
            request = SimpleNamespace(input_mode='voice', session_id='same-session', message='Hello', history=[], action_id=None,
                                      current_time='2026-09-09T10:00:00+00:00', timezone='UTC')
            run = service.create(request)
            await service.tasks[run['id']]
            events = store.events(run['id'])
            self.assertEqual(store.get_run(run['id'])['status'], 'succeeded')
            spoken = ''.join(e.get('content', '') for e in events if e['event'] == 'speech_segment')
            self.assertEqual(spoken, 'Hello.我是 Sophie。')
            self.assertNotIn('PRIVATE', str(events))
            self.assertNotIn('secret', str(events))
            self.assertNotIn('tools', client.requests[-1])
            self.assertEqual(store.messages('same-session')[-1]['content'], 'Hello. 我是 Sophie。')

    async def test_english_memory_uses_same_store_once(self):
        saved = []
        with tempfile.TemporaryDirectory() as folder:
            store = Store(Path(folder) / 'runs.sqlite3')
            agent = SimpleNamespace(memory=SimpleNamespace(remember=lambda text, **kw: saved.append((text, kw)) or True))
            service = RunService(store, SimpleNamespace(), SimpleNamespace(), agent=agent)
            run = service.create(SimpleNamespace(input_mode='voice', session_id='memory', message='Remember that I prefer tea.',
                                                  history=[], action_id=None))
            await service.tasks[run['id']]
            self.assertEqual(saved, [('I prefer tea.', {'source': 'explicit'})])
            self.assertEqual(store.get_run(run['id'])['status'], 'succeeded')
            self.assertTrue(any(e['event'] == 'speech_segment' for e in store.events(run['id'])))
