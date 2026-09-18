import asyncio
import os
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from agent.run_service import RunService
from runtime.store import Store
from skills.registry import Registry, SkillError
from tools.python_executor import PythonExecutor
from tools.workspace import WorkspaceExecutor

ROOT=Path(__file__).resolve().parents[2]

class WorkspaceTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp=tempfile.TemporaryDirectory()
        self.workspace=WorkspaceExecutor(Path(self.temp.name)/'workspace')
        self.store=Store(Path(self.temp.name)/'runs.db')
        self.registry=Registry(ROOT,self.store)
        self.service=RunService(self.store,self.registry,SimpleNamespace(actions=set()),python_executor=PythonExecutor(workspace=self.workspace))

    async def asyncTearDown(self):
        tasks=list(self.service.tasks.values())
        for task in tasks: task.cancel()
        await asyncio.gather(*tasks,return_exceptions=True)
        self.temp.cleanup()

    async def wait(self,id,status):
        for _ in range(200):
            run=self.store.get_run(id)
            if run['status']==status: return run
            await asyncio.sleep(.01)
        self.fail(str(run))

    def request(self,action,args):
        return SimpleNamespace(session_id='test',history=[],message=action,action_id=action,arguments=args,current_time='2026-09-18T10:00:00+08:00',timezone='Asia/Shanghai')

    async def test_write_requires_exact_approval_and_readback(self):
        args={'path':'hello.txt','content':'你好','expected_version':'absent'}
        run=self.service.create(self.request('workspace.write_file',args))
        pending=(await self.wait(run['id'],'waiting_approval'))['pending']
        self.assertFalse((self.workspace.root/'hello.txt').exists())
        with self.assertRaises(SkillError): self.service.approve(run['id'],pending['call_id'],'wrong',True)
        self.service.approve(run['id'],pending['call_id'],pending['digest'],True)
        await self.wait(run['id'],'succeeded')
        result=await self.workspace.execute('workspace.read_file',{'path':'hello.txt'})
        self.assertEqual(result['content'],'你好')
        self.assertEqual(len(result['version']),64)

    async def test_approval_reject_and_stale_version_do_not_write(self):
        for approve in (False,True):
            target=self.workspace.root/'hello.txt'
            target.unlink(missing_ok=True)
            run=self.service.create(self.request('workspace.write_file',{'path':'hello.txt','content':'new','expected_version':'absent'}))
            pending=(await self.wait(run['id'],'waiting_approval'))['pending']
            if approve: target.write_text('external change')
            self.service.approve(run['id'],pending['call_id'],pending['digest'],approve)
            await self.wait(run['id'],'failed')
            self.assertEqual(target.read_text() if target.exists() else '', 'external change' if approve else '')

    async def test_escape_symlink_hardlink_and_fifo_are_rejected(self):
        outside=Path(self.temp.name)/'secret';outside.write_text('secret')
        (self.workspace.root/'link').symlink_to(outside)
        os.link(outside,self.workspace.root/'hard')
        os.mkfifo(self.workspace.root/'pipe')
        for path in ('../secret',str(outside),'link','hard','pipe','.env'):
            with self.subTest(path=path), self.assertRaises(SkillError):
                await self.workspace.execute('workspace.read_file',{'path':path})

    async def test_disabled_workspace_not_callable(self):
        self.store.set_enabled('ark.workspace',False)
        with self.assertRaises(SkillError): self.service.create(self.request('workspace.list_files',{}))

    @unittest.skipUnless(os.getenv('ARK_TEST_SANDBOX')=='1','Explicit macOS sandbox integration test')
    async def test_real_shell_limits_read_write_network_and_timeout(self):
        result=await self.workspace.shell({'command':'printf hello > hello.txt; cat hello.txt'})
        self.assertEqual(result['stdout'],'hello')
        outside=Path(self.temp.name)/'outside';outside.write_text('secret')
        with self.assertRaises(SkillError): await self.workspace.shell({'command':f'cat "{outside}"'})
        with self.assertRaises(SkillError): await self.workspace.shell({'command':f'printf bad > "{outside}"'})
        self.assertEqual(outside.read_text(),'secret')
        with self.assertRaises(SkillError): await self.workspace.shell({'command':'/usr/bin/curl --max-time 2 http://127.0.0.1:8765/'})
        with self.assertRaises(SkillError) as timed:
            await self.workspace.shell({'command':'sleep 20','timeout_seconds':1})
        self.assertEqual(timed.exception.code,'RESULT_UNKNOWN')
        result=await self.workspace.shell({'command':'yes abc | head -c 20000'})
        self.assertTrue(result['truncated']);self.assertLessEqual(len(result['stdout']),6000)

    @unittest.skipUnless(os.getenv('ARK_TEST_SANDBOX')=='1','Explicit macOS sandbox integration test')
    async def test_cancel_kills_child_process(self):
        task=asyncio.create_task(self.workspace.shell({'command':'sleep 2; echo bad > late.txt'}))
        await asyncio.sleep(.2);task.cancel()
        with self.assertRaises(asyncio.CancelledError): await task
        await asyncio.sleep(2.1)
        self.assertFalse((self.workspace.root/'late.txt').exists())
