#!/usr/bin/env python3
"""Regenerate the signed-in-app native allowlist from validated manifests."""
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
skills = ["applications", "calendar", "reminders"]
digests, actions = {}, []
for name in skills:
    path = ROOT / "skills" / name / "manifest.json"
    raw = path.read_bytes()
    manifest = json.loads(raw)
    digests[manifest["id"]] = hashlib.sha256(raw).hexdigest()
    actions.extend(action["id"] for action in manifest["actions"] if action["executor"] == "native")
payload = {"protocol_version": "1.0", "digests": digests, "actions": actions}
target = ROOT / "frontend/ArkIntelligence/Resources/native-capabilities.json"
target.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n")
print(f"Updated {target.relative_to(ROOT)} with {len(actions)} actions")
