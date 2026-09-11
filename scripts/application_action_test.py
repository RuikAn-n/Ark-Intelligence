#!/usr/bin/env python3
"""Open and normally quit Calculator through the native action protocol."""
import json
import os
import time
from datetime import datetime
from pathlib import Path

import httpx

token = (Path.home() / "Library/Application Support/ArkIntelligence/runtime/token").read_text().strip()
client = httpx.Client(base_url=os.getenv("ARK_API_URL", "http://127.0.0.1:8765"), headers={"Authorization": "Bearer " + token}, timeout=15)
client.patch("/skills/ark.applications", json={"enabled": True}).raise_for_status()


def run(action):
    created = client.post("/runs", json={
        "session_id": "application-action-test", "message": action,
        "current_time": datetime.now().astimezone().isoformat(), "timezone": "Asia/Shanghai",
        "action_id": action, "arguments": {"bundle_id": "com.apple.calculator"}
    }).raise_for_status().json()
    for _ in range(200):
        state = client.get("/runs/" + created["id"]).raise_for_status().json()
        if state["status"] in {"succeeded", "failed", "result_unknown"}: break
        time.sleep(0.05)
    if state["status"] != "succeeded": raise SystemExit(json.dumps(state, ensure_ascii=False))
    events = client.get("/runs/" + created["id"] + "/events").text
    payloads = [json.loads(line.removeprefix("data: ")) for line in events.splitlines() if line.startswith("data: ")]
    return json.loads(next(item["content"] for item in payloads if item["event"] == "tool_finished"))


opened = run("applications.open_app")
closed = run("applications.quit_app")
passed = opened.get("verified") is True and closed.get("verified") is True
print(json.dumps({"passed": passed, "opened_pid": opened.get("pid"), "quit_verified": closed.get("verified")}, ensure_ascii=False))
raise SystemExit(0 if passed else 1)
