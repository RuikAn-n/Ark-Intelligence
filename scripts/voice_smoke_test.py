#!/usr/bin/env python3
"""Exercise real WS wake → VAD → ASR → audio generation without using a microphone."""
import asyncio
import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

import numpy as np
import soundfile as sf
from scipy.signal import resample_poly
from websockets.asyncio.client import connect

ROOT = Path(__file__).resolve().parents[1]


async def check(runtime):
    token = (runtime / 'token').read_text().strip()
    async with connect('ws://127.0.0.1:18766/voice', additional_headers={'Authorization': 'Bearer ' + token}, proxy=None, max_size=2_000_000) as socket:
        while True:
            event = json.loads(await asyncio.wait_for(socket.recv(), 120))
            if event['event'] == 'error': raise RuntimeError(event)
            if event['event'] == 'ready': break
        samples, rate = sf.read(ROOT / 'build/voice-benchmark/wake.wav', dtype='float32')
        assert rate == 24000
        samples = np.concatenate((resample_poly(samples, 2, 3), np.zeros(16000, dtype=np.float32)))
        async def feed():
            for start in range(0, len(samples), 512):
                await socket.send((np.clip(samples[start:start + 512], -1, 1) * 32767).astype('<i2').tobytes())
                await asyncio.sleep(0.032)
        feeder = asyncio.create_task(feed())
        seen = []
        transcript = None
        while transcript is None:
            event = json.loads(await asyncio.wait_for(socket.recv(), 30))
            seen.append(event['event'])
            if event['event'] == 'error': raise RuntimeError(event)
            if event['event'] == 'transcript': transcript = event['text']
        await feeder
        assert 'wake' in seen, seen
        assert 'weather' in transcript.lower(), transcript
        assert 'sophie' not in transcript.lower(), transcript
        await socket.send(json.dumps({'command':'speak','text':'你好，我是 Sophie。','id':'test-speech'}))
        while True:
            event = json.loads(await asyncio.wait_for(socket.recv(), 30))
            if event['event'] == 'error': raise RuntimeError(event)
            if event['event'] == 'audio':
                assert event['id'] == 'test-speech' and event['sample_rate'] == 24000
                break
        await socket.send(json.dumps({'command':'interrupt'}))
        while json.loads(await asyncio.wait_for(socket.recv(), 10))['event'] != 'interrupted': pass
        print(json.dumps({'fallback_only':'--fallback' in sys.argv, 'wake':True, 'transcript':transcript,'audio':True,'interrupt_ack':True}, ensure_ascii=False))


def main():
    with tempfile.TemporaryDirectory(prefix='ark-voice-smoke-') as folder:
        runtime = Path(folder)
        env = dict(os.environ, ARK_RUNTIME_DIR=folder, PYTHONPATH=str(ROOT / 'backend'), HF_HUB_OFFLINE='1')
        log_path = ROOT / 'build/voice-benchmark/server.log'
        with log_path.open('w') as log:
            command = [sys.executable, '-m', 'uvicorn', 'voice.server:app', '--host', '127.0.0.1', '--port', '18766', '--ws-max-size', '16384']
            if '--fallback' in sys.argv:
                # Test-only monkeypatch: prove the second path when KWS misses.
                command = [sys.executable, '-c', "from voice.models import Detector; Detector.wake = lambda self, samples: False; import uvicorn; uvicorn.run('voice.server:app', host='127.0.0.1', port=18766, ws_max_size=16384)"]
            process = subprocess.Popen(command, cwd=ROOT, env=env, stdout=log, stderr=log)
            try:
                for _ in range(100):
                    if process.poll() is not None: raise RuntimeError(log_path.read_text())
                    if (runtime / 'token').exists(): break
                    time.sleep(0.1)
                time.sleep(0.5)
                asyncio.run(check(runtime))
            finally:
                process.terminate()
                try: process.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    process.kill(); process.wait()


if __name__ == '__main__': main()
