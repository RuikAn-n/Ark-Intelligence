import hashlib
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch
from fastapi.testclient import TestClient
from api.server import app,local_token,hermes_token,run_service
from runtime.store import Store

class BridgeTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory()
        store=Store(Path(self.temp.name)/'runs.db')
        self.store_patch=patch.object(run_service.store,'path',store.path)
        self.store_patch.start()
        self.context=TestClient(app,base_url='http://127.0.0.1');self.client=self.context.__enter__()
        self.auth={'Authorization':'Bearer '+hermes_token}
        self.admin={'Authorization':'Bearer '+local_token}
        self.client.patch('/skills/ark.example',headers=self.admin,json={'enabled':True})

    def tearDown(self):
        self.context.__exit__(None,None,None)
        self.store_patch.stop();self.temp.cleanup()

    def payload(self,request_id='bridge-test'):
        return {'request_id':request_id,'session_id':'bridge','message':'echo','current_time':'2026-09-18T10:00:00+08:00',
                'timezone':'Asia/Shanghai','action_id':'example.echo','arguments':{'text':'ok'}}

    def test_scoped_token_cannot_approve_or_read_private_memory(self):
        for path in ('/skills','/memories','/runs'):
            self.assertEqual(self.client.get(path,headers=self.auth).status_code,401)
        self.assertEqual(self.client.post('/runs/x/approvals',headers=self.auth,json={}).status_code,401)
        self.assertEqual(self.client.get('/integrations/hermes/skills',headers=self.auth).status_code,200)
        self.assertEqual(self.client.get('/integrations/hermes/skills',headers={**self.auth,'Origin':'http://evil.test'}).status_code,401)

    def test_request_is_deduplicated_and_status_has_executor_result(self):
        first=self.client.post('/integrations/hermes/runs',headers=self.auth,json=self.payload())
        self.assertEqual(first.status_code,201,first.text)
        second=self.client.post('/integrations/hermes/runs',headers=self.auth,json=self.payload())
        self.assertEqual(first.json()['id'],second.json()['id'])
        run_id=first.json()['id']
        for _ in range(100):
            result=self.client.get('/integrations/hermes/runs/'+run_id,headers=self.auth).json()
            if result['status']=='succeeded': break
            time.sleep(.01)
        self.assertEqual(result['status'],'succeeded')
        self.assertEqual(len(result['calls']),1)
        payload=self.payload();payload['arguments']['text']='different'
        self.assertEqual(self.client.post('/integrations/hermes/runs',headers=self.auth,json=payload).status_code,409)

    def test_bridge_reminder_waits_for_app_approval(self):
        self.client.patch('/skills/ark.reminders',headers=self.admin,json={'enabled':True})
        executions=[]
        async def fake_native(envelope):
            if envelope['operation']=='prepare': return {'preview_token':'test','summary':'测试提醒事项'}
            executions.append(envelope)
            return {'verified':True}
        payload=self.payload('reminder-bridge');payload.update(action_id='reminders.create_reminder',arguments={'title':'桥接测试','list_id':'test'})
        with patch.object(run_service.bridge,'request',fake_native):
            response=self.client.post('/integrations/hermes/runs',headers=self.auth,json=payload)
            self.assertEqual(response.status_code,201,response.text)
            run_id=response.json()['id']
            for _ in range(100):
                state=self.client.get('/integrations/hermes/runs/'+run_id,headers=self.auth).json()
                if state['status']=='waiting_approval': break
                time.sleep(.01)
            self.assertEqual(state['status'],'waiting_approval',state)
            self.assertEqual(executions,[])
            pending=state['pending'];body={k:pending[k] for k in ('call_id','digest')};body['approved']=True
            self.assertEqual(self.client.post('/runs/'+run_id+'/approvals',headers=self.auth,json=body).status_code,401)
            self.assertEqual(self.client.post('/runs/'+run_id+'/approvals',headers=self.admin,json=body).status_code,200)
            for _ in range(100):
                state=self.client.get('/integrations/hermes/runs/'+run_id,headers=self.auth).json()
                if state['status']=='succeeded': break
                time.sleep(.01)
            self.assertEqual(state['status'],'succeeded',state)
            self.assertEqual(len(executions),1)
