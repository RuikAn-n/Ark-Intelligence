import asyncio
import tempfile
import time
import unittest
from pathlib import Path
from types import SimpleNamespace

from agent.run_service import RunService
from runtime.store import Store
from skills.registry import Registry, SkillError


ROOT = Path(__file__).resolve().parents[2]


class FakeBridge:
    def __init__(self):
        self.actions = {"calendar.create_event"}
        self.permissions = {"calendar": "fullAccess"}
        self.executions = 0

    async def request(self, envelope):
        if envelope["operation"] == "prepare":
            return {"preview_token": "native-preview", "summary": "新建测试日程"}
        self.executions += 1
        return {"verified": True}


class ApprovalTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.store = Store(Path(self.temp.name) / "runs.sqlite3")
        self.registry = Registry(ROOT, self.store)
        self.registry.store.set_enabled("ark.calendar", True)
        self.registry.store.set_enabled("ark.example", True)
        self.bridge = FakeBridge()
        self.service = RunService(self.store, self.registry, self.bridge)
        self.request = SimpleNamespace(
            session_id="approval-test", message="create", current_time="2026-09-05T22:00:00+08:00",
            timezone="Asia/Shanghai", history=[], action_id="calendar.create_event",
            arguments={"title": "测试", "start": "2026-09-06T15:00:00+08:00", "end": "2026-09-06T16:00:00+08:00", "timezone": "Asia/Shanghai", "calendar_id": "test"}
        )

    async def asyncTearDown(self):
        for task in self.service.tasks.values(): task.cancel()
        await asyncio.gather(*self.service.tasks.values(), return_exceptions=True)
        self.temp.cleanup()

    async def wait_for(self, status):
        return await self.wait_run(self.run["id"],status)

    async def wait_run(self, run_id, status):
        for _ in range(100):
            run = self.store.get_run(run_id)
            if run["status"] == status: return run
            await asyncio.sleep(0.01)
        self.fail(f"run did not reach {status}")

    async def test_rejection_never_executes_native_write(self):
        self.run = self.service.create(self.request)
        waiting = await self.wait_for("waiting_approval")
        pending = waiting["pending"]
        with self.assertRaises(SkillError):
            self.service.approve(self.run["id"], pending["call_id"], "wrong", True)
        self.service.approve(self.run["id"], pending["call_id"], pending["digest"], False)
        await self.wait_for("failed")
        self.assertEqual(self.bridge.executions, 0)

    async def test_exact_approval_executes_once(self):
        self.run = self.service.create(self.request)
        waiting = await self.wait_for("waiting_approval")
        pending = waiting["pending"]
        self.service.approve(self.run["id"], pending["call_id"], pending["digest"], True)
        await self.wait_for("succeeded")
        self.assertEqual(self.bridge.executions, 1)

    async def test_unverified_native_write_is_result_unknown(self):
        original=self.bridge.request
        async def unverified(envelope):
            data=await original(envelope)
            return {'verified':False} if envelope['operation']=='execute' else data
        self.bridge.request=unverified
        self.run=self.service.create(self.request)
        pending=(await self.wait_for('waiting_approval'))['pending']
        self.service.approve(self.run['id'],pending['call_id'],pending['digest'],True)
        await self.wait_for('result_unknown')
        self.assertEqual(self.bridge.executions,1)

    async def test_waiting_approval_does_not_block_another_background_run(self):
        self.run = self.service.create(self.request)
        await self.wait_for("waiting_approval")
        echo = SimpleNamespace(
            session_id="approval-test", message="echo", current_time="2026-09-05T22:00:00+08:00",
            timezone="Asia/Shanghai", history=[], action_id="example.echo", arguments={"text":"still responsive"}
        )
        second = self.service.create(echo)
        await self.wait_run(second["id"],"succeeded")
        self.assertEqual(self.store.get_run(self.run["id"])["status"],"waiting_approval")
        self.assertTrue(any(event["event"]=="progress" for event in self.store.events(second["id"])))

    async def test_active_run_limit_bounds_resource_pressure(self):
        runs=[]
        for index in range(self.service.max_active):
            request=SimpleNamespace(**vars(self.request))
            request.session_id=f"limit-{index}"
            runs.append(self.service.create(request))
        for run in runs: await self.wait_run(run["id"],"waiting_approval")
        with self.assertRaises(SkillError): self.service.create(self.request)
