import tempfile
import unittest
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from runtime.store import Store


class StoreTests(unittest.TestCase):
    def test_active_run_is_interrupted_after_restart(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "runs.sqlite3"
            first = Store(path)
            first.save_run({"id": "run", "session_id": "session", "status": "executing", "pending": None})
            second = Store(path)
            run = second.get_run("run")
            self.assertEqual(run["status"], "interrupted")
            self.assertIn("不得重放", run["error"])

    def test_events_are_ordered_and_resumable(self):
        with tempfile.TemporaryDirectory() as folder:
            store = Store(Path(folder) / "runs.sqlite3")
            first = store.event("run", {"event": "one"})
            store.event("run", {"event": "two"})
            events = store.events("run", after=first)
            self.assertEqual([event["event"] for event in events], ["two"])

    def test_concurrent_background_results_do_not_overwrite_session(self):
        with tempfile.TemporaryDirectory() as folder:
            store = Store(Path(folder) / "runs.sqlite3")
            store.append_messages("session", [{"role":"user","content":"start"}], max_messages=50)
            with ThreadPoolExecutor(max_workers=4) as pool:
                list(pool.map(lambda value: store.append_messages("session", [{"role":"assistant","content":value}], max_messages=50), [f"result-{i}" for i in range(12)]))
            contents={message["content"] for message in store.messages("session")}
            self.assertEqual(contents,{"start",*(f"result-{i}" for i in range(12))})

    def test_runs_and_calls_remain_queryable(self):
        with tempfile.TemporaryDirectory() as folder:
            store = Store(Path(folder) / "runs.sqlite3")
            store.save_run({"id":"run","session_id":"session","status":"queued"})
            store.call("call","run",{"status":"succeeded"})
            self.assertEqual(store.list_runs(session_id="session",active_only=True)[0]["id"],"run")
            self.assertEqual(store.calls("run"),[{"status":"succeeded"}])


if __name__ == "__main__":
    unittest.main()
