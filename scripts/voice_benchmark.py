#!/usr/bin/env python3
"""Synthetic local integration benchmark. No microphone recording or external upload."""
import json
import math
import sys
import threading
import time
from pathlib import Path

import numpy as np
import soundfile as sf
from scipy.signal import resample_poly

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'backend'))
from voice.models import Detector, SpeechModels


def main():
    output = ROOT / 'build/voice-benchmark'
    output.mkdir(parents=True, exist_ok=True)
    models = SpeechModels()
    start = time.monotonic()
    models.load()
    results = {'load_seconds': time.monotonic() - start, 'kind': 'synthetic round-trip, not human ASR accuracy', 'samples': []}
    for name, text in [('zh', '你好，我是 Sophie。今天想聊些什么？'), ('en', "Hello, I'm Sophie. What would you like to talk about?"), ('wake', 'Hey Sophie, tell me about the weather.')]:
        chunks, first = [], []
        started = time.monotonic()
        rate = 24000
        def emit(pcm, sample_rate):
            nonlocal rate
            rate = sample_rate
            if not first:
                first.append(time.monotonic() - started)
            chunks.append(np.frombuffer(pcm, dtype='<i2').astype(np.float32) / 32768)
        models.speak(text, threading.Event(), emit)
        duration = time.monotonic() - started
        if not chunks:
            raise RuntimeError('No audio was generated')
        audio = np.concatenate(chunks)
        sf.write(output / f'{name}.wav', audio, rate)
        gcd = math.gcd(rate, 16000)
        audio16 = resample_poly(audio, 16000 // gcd, rate // gcd).astype(np.float32)
        start = time.monotonic()
        transcript = models.transcribe(audio16)
        row = dict(name=name, text=text, transcript=transcript, tts_seconds=duration,
                   first_audio_seconds=first[0], audio_seconds=len(audio) / rate,
                   rtf=duration / (len(audio) / rate), asr_seconds=time.monotonic() - start)
        if name == 'wake':
            detector = Detector()
            hits = 0
            for offset in range(0, len(audio16), 512):
                hits += int(detector.wake(audio16[offset:offset + 512]))
            row['wake_detections'] = hits
        results['samples'].append(row)
        print(json.dumps(row, ensure_ascii=False), flush=True)
        (output / 'results.json').write_text(json.dumps(results, ensure_ascii=False, indent=2))
    import mlx.core as mx
    results['mlx_peak_memory_bytes'] = mx.get_peak_memory()
    (output / 'results.json').write_text(json.dumps(results, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
