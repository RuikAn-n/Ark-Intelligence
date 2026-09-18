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
from voice.input_guard import has_speech_energy
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
        self.assertTrue(session.manual_input)
        await session.control({'command':'arm'})
        self.assertFalse(session.awake)
        self.assertFalse(session.manual_input)

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

    def test_noise_energy_rejects_silence_and_loud_impulse(self):
        samples = np.zeros(16000, dtype=np.float32)
        self.assertFalse(has_speech_energy(samples))
        samples[100:180] = 0.9
        self.assertFalse(has_speech_energy(samples))
        samples[1000:9000] = 0.02
        self.assertTrue(has_speech_energy(samples))
        self.assertFalse(has_speech_energy(samples, noise_floor=0.01))

    async def test_vad_onset_does_not_interrupt_playback(self):
        socket = FakeSocket()
        session = VoiceSession(socket)
        session.awake = session.playing = True
        session.detector = SimpleNamespace(wake=lambda samples: False, vad=SimpleNamespace(
            accept_waveform=lambda samples: None, is_speech_detected=lambda: True, empty=lambda: True))
        epoch = session.epoch
        await session.audio(np.full(1600, 0.05, dtype=np.float32))
        self.assertEqual(session.epoch, epoch)
        self.assertTrue(session.playing)
        self.assertNotIn('speech_started', [e['event'] for e in socket.events])

    async def test_background_transcript_cannot_interrupt_or_enter_chat(self):
        socket = FakeSocket()
        session = VoiceSession(socket)
        session.awake = session.playing = session.waiting_answer = True
        with patch('voice.server.models.transcribe', return_value='这是什么声音？'):
            await session.transcribe(np.zeros(16000), session.epoch, False, require_wake=True)
        self.assertEqual(socket.events, [])
        self.assertTrue(session.playing)
        self.assertTrue(session.waiting_answer)
        self.assertEqual(session.epoch, 0)

    async def test_explicit_wake_interrupts_before_committing_transcript(self):
        socket = FakeSocket()
        session = VoiceSession(socket)
        session.awake = session.playing = True
        with patch('voice.server.models.transcribe', return_value='Hey Sophie, 换一个问题。'):
            await session.transcribe(np.zeros(16000), session.epoch, False, require_wake=True)
        events = [e['event'] for e in socket.events]
        self.assertLess(events.index('speech_started'), events.index('transcript'))
        self.assertEqual(next(e['text'] for e in socket.events if e['event'] == 'transcript'), '换一个问题。')
        self.assertFalse(session.playing)

    async def test_short_valid_reply_is_preserved_after_manual_listen(self):
        socket = FakeSocket()
        session = VoiceSession(socket)
        session.awake = True
        with patch('voice.server.models.transcribe', return_value='好。'):
            await session.transcribe(np.zeros(16000), session.epoch, False)
        self.assertEqual(next(e['text'] for e in socket.events if e['event'] == 'transcript'), '好。')

    def test_strip_only_leading_wake_word(self):
        self.assertEqual(strip_wake('Hey Sophie, 打开日历。'), '打开日历。')
        self.assertEqual(strip_wake('Tell Sophie about it.'), 'Tell Sophie about it.')


if __name__ == '__main__': unittest.main()
