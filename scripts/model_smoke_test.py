#!/usr/bin/env python3
"""Read-only natural-language tool-loop check using the configured local model."""
import json
import os
import time
import uuid
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

import httpx

token = (Path.home() / "Library/Application Support/ArkIntelligence/runtime/token").read_text().strip()
client = httpx.Client(base_url=os.getenv("ARK_API_URL", "http://127.0.0.1:8765"), headers={"Authorization": "Bearer " + token}, timeout=15)
client.patch("/skills/ark.applications", json={"enabled": True}).raise_for_status()
now = datetime.now().astimezone()
run = client.post("/runs", json={
    "session_id": "model-smoke-test-" + uuid.uuid4().hex[:12],
    "message": "请使用工具查看当前有哪些正在运行的用户应用，只告诉我前三个。",
    "current_time": now.isoformat(),
    "timezone": now.tzinfo.key if isinstance(now.tzinfo, ZoneInfo) else "Asia/Shanghai"
}).raise_for_status().json()
for _ in range(1_800):
    state = client.get("/runs/" + run["id"]).raise_for_status().json()
    if state["status"] in {"succeeded", "failed", "cancelled", "result_unknown"}: break
    time.sleep(0.1)
else: raise SystemExit("Model smoke test timed out")
events = client.get("/runs/" + run["id"] + "/events").text
passed = state["status"] == "succeeded" and "applications.list_running_apps" in events and "tool_finished" in events
print(json.dumps({"passed": passed, "status": state["status"], "used_action": "applications.list_running_apps" in events}, ensure_ascii=False))
raise SystemExit(0 if passed else 1)
