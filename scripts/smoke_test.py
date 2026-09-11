#!/usr/bin/env python3
"""Read-only end-to-end check for API authentication and the native app bridge."""
import json
import os
import time
from pathlib import Path

import httpx

token_path = Path.home() / "Library/Application Support/ArkIntelligence/runtime/token"
token = token_path.read_text().strip()
headers = {"Authorization": "Bearer " + token}
client = httpx.Client(base_url=os.getenv("ARK_API_URL", "http://127.0.0.1:8765"), headers=headers, timeout=10)

health = client.get("/").raise_for_status().json()
skills = client.get("/skills").raise_for_status().json()["skills"]
applications = next(skill for skill in skills if skill["id"] == "ark.applications")
if not applications["available"]:
    raise SystemExit("Native application capability is unavailable; open the packaged Ark app first")
client.patch("/skills/ark.applications", json={"enabled": True}).raise_for_status()
run = client.post("/runs", json={
    "session_id": "smoke-test", "message": "read-only native smoke test",
    "current_time": "2026-09-05T22:00:00+08:00", "timezone": "Asia/Shanghai",
    "action_id": "applications.find_apps", "arguments": {"query": "Safari"}
}).raise_for_status().json()

for _ in range(100):
    state = client.get("/runs/" + run["id"]).raise_for_status().json()
    if state["status"] in {"succeeded", "failed", "cancelled", "result_unknown"}: break
    time.sleep(0.05)
else:
    raise SystemExit("Smoke-test run timed out")
if state["status"] != "succeeded": raise SystemExit(json.dumps(state, ensure_ascii=False))
events = client.get("/runs/" + run["id"] + "/events").text
payloads = [json.loads(line.removeprefix("data: ")) for line in events.splitlines() if line.startswith("data: ")]
finished = next((json.loads(item["content"]) for item in payloads if item["event"] == "tool_finished"), {})
apps = finished.get("apps", [])
if not finished.get("verified") or not any(app.get("bundle_id") == "com.apple.Safari" for app in apps):
    raise SystemExit("Safari was not returned and verified by the native host")
print(json.dumps({
    "passed": True, "resource_profile": health["resource_profile"],
    "native_skill_count": sum(skill["available"] for skill in skills),
    "checked_action": "applications.find_apps"
}, ensure_ascii=False))
