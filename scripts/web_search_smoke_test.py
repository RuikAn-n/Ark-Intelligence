#!/usr/bin/env python3
"""Real-network and model-routing smoke test for the web search Skill."""
import json
import os
import time
import uuid
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

import httpx


token=(Path.home()/ "Library/Application Support/ArkIntelligence/runtime/token").read_text().strip()
client=httpx.Client(
    base_url=os.getenv("ARK_API_URL","http://127.0.0.1:8765"),
    headers={"Authorization":"Bearer "+token},
    timeout=20,
)
client.patch("/skills/ark.web_search",json={"enabled":True}).raise_for_status()


def wait(run_id, seconds=180):
    for _ in range(seconds*2):
        state=client.get("/runs/"+run_id).raise_for_status().json()
        if state["status"] in {"succeeded","failed","cancelled","result_unknown"}: return state
        time.sleep(0.5)
    raise SystemExit("Web search smoke test timed out")


def events(run_id):
    text=client.get("/runs/"+run_id+"/events").text
    return [json.loads(line.removeprefix("data: ")) for line in text.splitlines() if line.startswith("data: ")]


direct=client.post("/runs",json={
    "session_id":"web-direct-"+uuid.uuid4().hex[:12],
    "message":"direct web search smoke test",
    "current_time":datetime.now().astimezone().isoformat(),
    "timezone":"Asia/Shanghai",
    "action_id":"web.search",
    "arguments":{"query":"site:python.org latest Python release","count":3,"recency_days":365},
}).raise_for_status().json()
direct_state=wait(direct["id"],30)
direct_events=events(direct["id"])
finished=next((json.loads(item["content"]) for item in direct_events if item["event"]=="tool_finished"),{})
results=finished.get("results",[])
direct_ok=direct_state["status"]=="succeeded" and bool(results) and all(item["url"].startswith(("http://","https://")) for item in results)

now=datetime.now().astimezone()
natural=client.post("/runs",json={
    "session_id":"web-model-"+uuid.uuid4().hex[:12],
    "message":"请根据当前时间，搜索 Python 官网最近的版本发布信息；先搜索，再读取至少一个最相关的 python.org 页面，简要总结并附上可点击的来源链接。",
    "current_time":now.isoformat(),
    "timezone":now.tzinfo.key if isinstance(now.tzinfo,ZoneInfo) else "Asia/Shanghai",
}).raise_for_status().json()
natural_state=wait(natural["id"])
natural_events=events(natural["id"])
used_search=any(item.get("action_id")=="web.search" for item in natural_events)
used_page=any(item.get("event")=="tool_finished" and item.get("action_id")=="web.fetch_page" for item in natural_events)
answer=next((item.get("content","") for item in natural_events if item["event"]=="answer"),"")
natural_ok=natural_state["status"]=="succeeded" and used_search and used_page and "http" in answer

print(json.dumps({
    "passed":direct_ok and natural_ok,
    "provider":finished.get("provider"),
    "result_count":len(results),
    "model_used_search":used_search,
    "model_read_page":used_page,
    "answer_has_link":"http" in answer,
},ensure_ascii=False))
client.close()
raise SystemExit(0 if direct_ok and natural_ok else 1)
