"""Offline-only MLX and ONNX adapters. All MLX work stays on one executor thread."""
import os
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MODEL_DIR = Path(os.environ.get('ARK_VOICE_MODEL_DIR', ROOT / '.voice-models'))
KWS_DIR = MODEL_DIR / 'sherpa-onnx-kws-zipformer-zh-en-3M-2025-12-20'


class SpeechModels:
    def __init__(self):
        self.asr = self.tts = None
        self.warmed = False

    def load(self):
        if self.asr is not None and self.tts is not None:
            return
        if not all((MODEL_DIR / name).exists() for name in ('asr/config.json', 'tts/config.json', 'hey-sophie.txt', 'silero_vad.onnx')):
            raise RuntimeError('语音模型缺失，请先运行 scripts/prepare_voice_models.py')
        # No automatic network downloads when listening to the microphone.
        os.environ['HF_HUB_OFFLINE'] = '1'
        from mlx_audio.stt import load
        from mlx_audio.tts.utils import load_model
        self.asr = load(str(MODEL_DIR / 'asr'))
        self.tts = load_model(str(MODEL_DIR / 'tts'))

    def warmup(self):
        import numpy as np
        import threading
        from scipy.signal import resample_poly
        self.load()
        if self.warmed:
            return
        chunks = []
        self.speak('你好。Hello.', threading.Event(), lambda pcm, rate: chunks.append(pcm))
        if chunks:
            pcm = np.frombuffer(b''.join(chunks), dtype='<i2').astype(np.float32) / 32768
            self.transcribe(resample_poly(pcm, 2, 3).astype(np.float32))
        self.warmed = True

    def transcribe(self, samples):
        import mlx.core as mx
        self.load()
        result = self.asr.generate(mx.array(samples), max_tokens=256)
        return result.text.strip()

    def speak(self, text, stop, emit):
        import numpy as np
        self.load()
        for result in self.tts.generate(text=text, voice='serena', lang_code='auto', stream=True,
                                        streaming_interval=0.32, max_tokens=512):
            if stop.is_set():
                break
            pcm = (np.clip(np.asarray(result.audio), -1, 1) * 32767).astype('<i2').tobytes()
            emit(pcm, result.sample_rate)


class Detector:
    def __init__(self):
        import sherpa_onnx
        self.kws = sherpa_onnx.KeywordSpotter(
            tokens=str(KWS_DIR / 'tokens.txt'),
            encoder=str(KWS_DIR / 'encoder-epoch-13-avg-2-chunk-8-left-64.int8.onnx'),
            decoder=str(KWS_DIR / 'decoder-epoch-13-avg-2-chunk-8-left-64.onnx'),
            joiner=str(KWS_DIR / 'joiner-epoch-13-avg-2-chunk-8-left-64.int8.onnx'),
            keywords_file=str(MODEL_DIR / 'hey-sophie.txt'), num_threads=1,
            keywords_threshold=0.3, num_trailing_blanks=2,
        )
        self.stream = self.kws.create_stream()
        config = sherpa_onnx.VadModelConfig()
        config.silero_vad.model = str(MODEL_DIR / 'silero_vad.onnx')
        config.silero_vad.min_silence_duration = 0.65
        config.silero_vad.min_speech_duration = 0.20
        config.silero_vad.max_speech_duration = 25
        config.sample_rate = 16000
        config.num_threads = 1
        self.vad = sherpa_onnx.VoiceActivityDetector(config, buffer_size_in_seconds=30)

    def wake(self, samples):
        self.stream.accept_waveform(16000, samples)
        while self.kws.is_ready(self.stream):
            self.kws.decode_stream(self.stream)
            if self.kws.get_result(self.stream):
                self.kws.reset_stream(self.stream)
                return True
        return False

    def reset(self):
        self.vad.reset()
        self.kws.reset_stream(self.stream)
