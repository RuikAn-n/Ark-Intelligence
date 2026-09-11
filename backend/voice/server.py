"""Bounded, authenticated local audio transport. Does not execute tools or store memories."""
import asyncio
import base64
import contextlib
import json
import re
import threading
import time
from concurrent.futures import ThreadPoolExecutor

import numpy as np
from fastapi import FastAPI, WebSocket, WebSocketDisconnect, Request, HTTPException

from runtime.security import authenticated, get_token
from voice.models import Detector, SpeechModels

app = FastAPI()
models = SpeechModels()
executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix='sophie-mlx')
token = get_token()
connected = False
diagnostics = {}


@app.get('/health')
async def health(request: Request):
    if not authenticated(request.headers, token):
        raise HTTPException(401, '需要可信本地客户端身份')
    return dict(connected=connected, **diagnostics)


WAKE_PREFIX = re.compile(
    r'^\s*(?:hey[\s,，!！-]+(?:sophie|sofie|sophy)\b|(?:嘿|嗨)[\s，,！!]*(?:苏菲|索菲|苏非))'
    r'[\s,，.。!！:：]*', re.I)


def wake_remainder(text):
    match = WAKE_PREFIX.match(text)
    return text[match.end():].strip() if match else None


def strip_wake(text):
    remainder = wake_remainder(text)
    if remainder is not None:
        return remainder
    return re.sub(r'^\s*(?:hey\s+)?sophie\b[\s,，.。!！:：]*', '', text, flags=re.I).strip()


@app.websocket('/voice')
async def voice(socket: WebSocket):
    global connected
    if not authenticated(socket.headers, token, allow_origin=True):
        await socket.close(code=1008)
        return
    if connected:
        await socket.close(code=1013, reason='已有语音连接')
        return
    connected = True
    await socket.accept()
    session = VoiceSession(socket)
    try:
        await session.run()
    except (WebSocketDisconnect, asyncio.CancelledError):
        pass
    except Exception as exc:
        with contextlib.suppress(Exception):
            await session.send('error', message=str(exc)[:300])
    finally:
        await session.close()
        with contextlib.suppress(Exception):
            await socket.close()
        connected = False


class VoiceSession:
    def __init__(self, socket):
        self.socket = socket
        self.lock = asyncio.Lock()
        self.queue = asyncio.Queue(maxsize=16)
        self.stop = threading.Event()
        self.epoch = 0
        self.awake = False
        self.last_activity = time.monotonic()
        self.speech_active = False
        self.transcribing = False
        self.wake_check_pending = False
        self.synthesizing = False
        self.playing = False
        self.waiting_answer = False
        self.tasks = set()
        self.ring = np.zeros(0, dtype=np.float32)
        self.detector = None
        self.strip_next_wake = False
        self.frame_count = 0
        self.sample_count = 0
        self.last_meter = 0.0
        self.max_peak = 0.0

    async def send(self, event, **data):
        async with self.lock:
            await self.socket.send_json(dict(event=event, **data))

    def background(self, coroutine):
        task = asyncio.create_task(coroutine)
        self.tasks.add(task)
        task.add_done_callback(self.tasks.discard)
        return task

    async def run(self):
        diagnostics.clear()
        await self.send('status', state='loading', message='正在加载本地语音模型')
        await asyncio.get_running_loop().run_in_executor(executor, models.warmup)
        self.detector = Detector()
        self.background(self.speech_loop())
        await self.send('ready', sample_rate=16000, state='armed')
        while True:
            packet = await asyncio.wait_for(self.socket.receive(), timeout=60)
            if packet['type'] == 'websocket.disconnect':
                break
            if packet.get('bytes') is not None:
                data = packet['bytes']
                if not data or len(data) > 8192 or len(data) % 2:
                    raise ValueError('音频帧必须是最多 4096 个 16kHz PCM16 单声道采样')
                await self.audio(np.frombuffer(data, dtype='<i2').astype(np.float32) / 32768)
            elif packet.get('text') is not None:
                if len(packet['text']) > 4096:
                    raise ValueError('控制消息过大')
                await self.control(json.loads(packet['text']))

    async def control(self, message):
        command = message.get('command')
        if command == 'capture_status':
            dropped = message.get('dropped_packets')
            if not isinstance(dropped, int) or isinstance(dropped, bool) or not 0 <= dropped <= 1_000_000_000:
                raise ValueError('无效采集统计')
            diagnostics['capture_dropped_packets'] = dropped
        elif command == 'listen':
            await self.interrupt()
            self.awake = True
            self.strip_next_wake = False
            self.last_activity = time.monotonic()
            self.detector.reset()
            self.speech_active = False
            await self.send('status', state='listening')
        elif command == 'arm':
            await self.interrupt()
            self.awake = False
            self.detector.reset()
            self.speech_active = False
            await self.send('status', state='armed')
        elif command == 'interrupt':
            await self.interrupt()
        elif command == 'playback':
            self.playing = bool(message.get('active'))
            self.last_activity = time.monotonic()
        elif command == 'thinking':
            self.waiting_answer = bool(message.get('active'))
            self.last_activity = time.monotonic()
        elif command == 'speak':
            text, speech_id = message.get('text'), message.get('id')
            if not isinstance(text, str) or not 1 <= len(text) <= 600 or not isinstance(speech_id, str) or len(speech_id) > 100:
                raise ValueError('无效语音合成请求')
            if self.queue.full():
                raise ValueError('语音播放队列已满')
            self.queue.put_nowait((text, speech_id, self.epoch))
        else:
            raise ValueError('未知语音控制命令')

    async def interrupt(self):
        self.epoch += 1
        self.stop.set()
        self.playing = False
        self.waiting_answer = False
        while not self.queue.empty():
            self.queue.get_nowait()
        await self.send('interrupted')

    async def audio(self, samples):
        now = time.monotonic()
        self.frame_count += 1
        self.sample_count += len(samples)
        rms = float(np.sqrt(np.mean(samples * samples))) if len(samples) else 0.0
        peak = float(np.max(np.abs(samples))) if len(samples) else 0.0
        self.max_peak = max(self.max_peak, peak)
        if now - self.last_meter >= 0.1:
            self.last_meter = now
            diagnostics.update(frames=self.frame_count, seconds=self.sample_count / 16000,
                               rms=rms, peak=peak, max_peak=self.max_peak, awake=self.awake,
                               speech=self.speech_active, transcribing=self.transcribing)
            await self.send('input_level', rms=rms, peak=peak, frames=self.frame_count)
        self.ring = np.concatenate((self.ring, samples))[-32000:]
        if not self.awake:
            if self.detector.wake(samples):
                self.awake = True
                self.speech_active = True
                self.strip_next_wake = True
                self.last_activity = now
                self.detector.vad.reset()
                self.detector.vad.accept_waveform(self.ring)
                await self.send('wake', state='listening')
                return
            # A small KWS model can miss accents. Check completed short speech
            # locally with ASR; ordinary speech never enters chat or memory.
            if not self.playing:
                self.detector.vad.accept_waveform(samples)
                if not self.detector.vad.empty():
                    segment = np.asarray(self.detector.vad.front.samples, dtype=np.float32).copy()
                    self.detector.vad.pop()
                    self.detector.vad.reset()
                    if not self.wake_check_pending and 5600 <= len(segment) <= 128000:
                        self.wake_check_pending = True
                        self.background(self.check_wake(segment, self.epoch))
            return
        if self.transcribing:
            return
        self.detector.vad.accept_waveform(samples)
        talking = self.detector.vad.is_speech_detected()
        if talking:
            self.last_activity = now
            if not self.speech_active:
                self.speech_active = True
                await self.interrupt()
                await self.send('speech_started', state='listening')
        if not self.detector.vad.empty():
            segment = np.asarray(self.detector.vad.front.samples, dtype=np.float32).copy()
            self.detector.vad.pop()
            self.detector.vad.reset()
            self.speech_active = False
            self.transcribing = True
            self.background(self.transcribe(segment, self.epoch, self.strip_next_wake))
            self.strip_next_wake = False
        elif not talking and not self.playing and not self.synthesizing and self.queue.empty() and now - self.last_activity > (300 if self.waiting_answer else 30):
            self.awake = False
            self.detector.reset()
            await self.send('status', state='armed')

    async def check_wake(self, samples, epoch):
        try:
            text = await asyncio.get_running_loop().run_in_executor(executor, models.transcribe, samples)
            if self.awake or epoch != self.epoch:
                return
            remainder = wake_remainder(text)
            if remainder is None:
                return
            self.awake = True
            self.speech_active = False
            self.strip_next_wake = False
            self.last_activity = time.monotonic()
            self.detector.reset()
            await self.send('wake', state='listening')
            if remainder:
                await self.send('transcript', text=remainder, farewell=False)
        except Exception:
            # KWS stays available if the secondary recognizer fails.
            await self.send('wake_check_unavailable')
        finally:
            self.wake_check_pending = False

    async def transcribe(self, samples, epoch, remove_wake):
        try:
            await self.send('status', state='processing')
            text = await asyncio.get_running_loop().run_in_executor(executor, models.transcribe, samples)
            if epoch != self.epoch:
                return
            if remove_wake:
                text = strip_wake(text)
            if text:
                farewell = text.lower().strip(' .。!！') in {'再见', '先这样', '结束对话', 'goodbye', 'bye sophie', 'stop listening'}
                await self.send('transcript', text=text, farewell=farewell)
                if farewell:
                    self.awake = False
            self.last_activity = time.monotonic()
            await self.send('status', state='listening' if self.awake else 'armed')
        except Exception as exc:
            await self.send('error', message=f'识别失败：{str(exc)[:200]}')
        finally:
            self.transcribing = False

    async def speech_loop(self):
        loop = asyncio.get_running_loop()
        while True:
            text, speech_id, epoch = await self.queue.get()
            if epoch != self.epoch:
                continue
            stop = self.stop = threading.Event()
            self.synthesizing = True

            def emit(pcm, rate):
                if stop.is_set():
                    return
                future = asyncio.run_coroutine_threadsafe(
                    self.send('audio', id=speech_id, sample_rate=rate, pcm=base64.b64encode(pcm).decode()), loop)
                try:
                    future.result(timeout=10)
                except Exception:
                    stop.set()
                    future.cancel()

            try:
                await loop.run_in_executor(executor, models.speak, text, stop, emit)
                if epoch == self.epoch:
                    await self.send('speech_done', id=speech_id)
            except Exception as exc:
                await self.send('error', message=f'合成失败：{str(exc)[:200]}')
            finally:
                self.synthesizing = False
                self.last_activity = time.monotonic()

    async def close(self):
        self.stop.set()
        for task in list(self.tasks):
            task.cancel()
        await asyncio.gather(*self.tasks, return_exceptions=True)
