#!/usr/bin/env python3
"""Exercise the real local model with synthetic data; never read user notifications."""
import asyncio
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'backend'))
from api.notifications_api import NotificationSummarizer


async def main():
    event = {'id':'synthetic-notification-test', 'source_app':'微信（合成测试）',
             'title':'项目群', 'body':'明天下午三点讨论项目，请带上实验结果。',
             'occurred_at':'2026-09-21T05:00:00Z', 'time_precision':'exact'}
    answer = await NotificationSummarizer(os.getenv('ARK_MAIN_MODEL', 'qwen3.5:9b-mlx'), asyncio.Lock()).summarize([event])
    assert answer.strip(), 'Empty summary'
    print(answer)


if __name__ == '__main__':
    try:
        asyncio.run(main())
    except Exception as exc:
        print(f'Local notification summary smoke test failed: {type(exc).__name__}: {exc}', file=sys.stderr)
        sys.exit(1)
