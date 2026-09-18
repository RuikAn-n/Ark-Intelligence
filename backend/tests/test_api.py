import os
import tempfile
import time
import unittest
from pathlib import Path

_runtime = tempfile.TemporaryDirectory()
os.environ["ARK_RUNTIME_DIR"] = _runtime.name

from fastapi.testclient import TestClient
from api.server import app, local_token


def tearDownModule():
    _runtime.cleanup()


class APITests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.client_context = TestClient(app, base_url="http://127.0.0.1")
        cls.client = cls.client_context.__enter__()
        cls.auth = {"Authorization": "Bearer " + local_token}

    @classmethod
    def tearDownClass(cls):
        cls.client_context.__exit__(None, None, None)

    def test_authentication_and_skills(self):
        self.assertEqual(self.client.get("/skills").status_code, 401)
        response = self.client.get("/skills", headers=self.auth)
        self.assertEqual(response.status_code, 200)
        self.assertIn('ark.workspace', {s['id'] for s in response.json()['skills']})
        web = next(item for item in response.json()["skills"] if item["id"] == "ark.web_search")
        self.assertTrue(web["isEnabled"])

    def test_direct_echo_run_and_resumable_events(self):
        response = self.client.patch("/skills/ark.example", headers=self.auth, json={"enabled": True})
        self.assertEqual(response.status_code, 200)
        run = self.client.post("/runs", headers=self.auth, json={
            "session_id": "api-test", "message": "echo", "current_time": "2026-09-05T22:00:00+08:00",
            "timezone": "Asia/Shanghai", "action_id": "example.echo", "arguments": {"text": "ok"}
        })
        self.assertEqual(run.status_code, 201, run.text)
        run_id = run.json()["id"]
        for _ in range(50):
            state = self.client.get(f"/runs/{run_id}", headers=self.auth).json()
            if state["status"] in {"succeeded", "failed"}: break
            time.sleep(0.01)
        self.assertEqual(state["status"], "succeeded")
        listed = self.client.get("/runs", headers=self.auth, params={"session_id":"api-test"})
        self.assertEqual(listed.status_code, 200)
        self.assertIn(run_id, [item["id"] for item in listed.json()["runs"]])
        calls = self.client.get(f"/runs/{run_id}/calls", headers=self.auth)
        self.assertEqual(calls.status_code, 200)
        self.assertEqual(calls.json()["calls"][0]["action_id"], "example.echo")
        with self.client.stream("GET", f"/runs/{run_id}/events", headers=self.auth) as stream:
            text = "".join(stream.iter_text())
        self.assertIn("tool_finished", text)
        self.assertIn('\\"text\\": \\"ok\\"', text)


if __name__ == "__main__": unittest.main()
