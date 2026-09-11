"""Run with .voice-venv: no real GPU or microphone needed."""
import asyncio
import os
import tempfile
import unittest
import numpy as np
from unittest.mock import patch
from types import SimpleNamespace

runtime = tempfile.TemporaryDirectory(prefix='sophie-unit-')
os.environ['ARK_RUNTIME_DIR'] = runtime.name
from voice.server import VoiceSession, strip_wake, wake_remainder


class FakeSocket:
    def __init__(self): self.events = []
    async def send_json(self, value): self.events.append(value)


class SessionTests(unittest.IsolatedAsyncioTestCase):
    async def test_interrupt_invalidates_current_and_queued_speech(self):
        session = VoiceSession(FakeSocket())
        await session.control({'command':'speak','text':'Old answer','id':'old'})
        stop, epoch = session.stop, session.epoch
        await session.interrupt()
        self.assertTrue(stop.is_set())
        self.assertTrue(session.queue.empty())
        self.assertGreater(session.epoch, epoch)

    async def test_invalid_or_unbounded_commands_are_rejected(self):
        session = VoiceSession(FakeSocket())
        for value in ({'command':'speak','text':'x'*601,'id':'x'}, {'command':'execute'}, {'command':'speak','text':3,'id':'x'}):
            with self.assertRaises(ValueError): await session.control(value)
        for i in range(16): await session.control({'command':'speak','text':'hello','id':str(i)})
        with self.assertRaises(ValueError): await session.control({'command':'speak','text':'overflow','id':'x'})

    async def test_arm_and_manual_listen_reset_detector_state(self):
        session = VoiceSession(FakeSocket())
        session.detector = SimpleNamespace(reset=lambda: None)
        await session.control({'command':'listen'})
        self.assertTrue(session.awake)
        await session.control({'command':'arm'})
        self.assertFalse(session.awake)

    async def test_input_meter_reports_signal_while_waiting_for_wake(self):
        socket = FakeSocket()
        session = VoiceSession(socket)
        session.detector = SimpleNamespace(wake=lambda samples: False, vad=SimpleNamespace(accept_waveform=lambda samples: None, empty=lambda: True))
        await session.audio(np.full(1600, 0.25, dtype=np.float32))
        meter = next(event for event in socket.events if event['event'] == 'input_level')
        self.assertAlmostEqual(meter['rms'], 0.25)
        self.assertAlmostEqual(meter['peak'], 0.25)
        self.assertFalse(session.awake)
        self.assertEqual(session.sample_count, 1600)

    async def test_asr_fallback_wakes_and_forwards_only_remainder(self):
        socket = FakeSocket()
        session = VoiceSession(socket)
        session.detector = SimpleNamespace(reset=lambda: None)
        with patch('voice.server.models.transcribe', return_value='Hey Sofie, 你好。'):
            await session.check_wake(np.zeros(16000, dtype=np.float32), session.epoch)
        self.assertTrue(session.awake)
        self.assertEqual([event['event'] for event in socket.events], ['wake', 'transcript'])
        self.assertEqual(socket.events[-1]['text'], '你好。')

    async def test_fallback_ignores_ordinary_speech_and_stale_results(self):
        for text, stale in [('今天的天气不错。', False), ('Hey Sophie, hello.', True)]:
            socket = FakeSocket()
            session = VoiceSession(socket)
            session.detector = SimpleNamespace(reset=lambda: None)
            with patch('voice.server.models.transcribe', return_value=text):
                await session.check_wake(np.zeros(16000, dtype=np.float32), session.epoch - int(stale))
            self.assertFalse(session.awake)
            self.assertEqual(socket.events, [])
            self.assertFalse(session.wake_check_pending)

    def test_wake_fallback_requires_explicit_prefix(self):
        self.assertEqual(wake_remainder('嗨苏菲，你好'), '你好')
        self.assertEqual(wake_remainder('Hey Sophie!'), '')
        for text in ['Sophie is a name.', 'They said hey Sophie.', '你好', 'Hey Sophia']:
            self.assertIsNone(wake_remainder(text))

    def test_strip_only_leading_wake_word(self):
        self.assertEqual(strip_wake('Hey Sophie, 打开日历。'), '打开日历。')
        self.assertEqual(strip_wake('Tell Sophie about it.'), 'Tell Sophie about it.')


if __name__ == '__main__': unittest.main()
