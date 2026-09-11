#!/usr/bin/env python3
"""Print aggregate local audio diagnostics, never raw audio or authentication data."""
import json
import os
from pathlib import Path
from urllib.request import Request, build_opener, ProxyHandler

runtime = Path(os.environ.get('ARK_RUNTIME_DIR', Path.home() / 'Library/Application Support/ArkIntelligence/runtime'))
request = Request('http://127.0.0.1:8766/health', headers={'Authorization': 'Bearer ' + (runtime / 'token').read_text().strip()})
with build_opener(ProxyHandler({})).open(request, timeout=5) as response:
    print(json.dumps(json.load(response), ensure_ascii=False, indent=2))
