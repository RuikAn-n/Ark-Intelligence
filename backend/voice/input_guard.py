"""Acoustic evidence before ASR; no transcript-content blacklist."""
import numpy as np


def has_speech_energy(samples, noise_floor=0.0005):
    samples = np.asarray(samples, dtype=np.float32)
    if not np.isfinite(samples).all() or len(samples) < 3840:
        return False
    frames = samples[:len(samples) // 320 * 320].reshape(-1, 320)
    rms = np.sqrt(np.mean(frames * frames, axis=1))
    active = rms > max(0.0015, min(noise_floor, 0.01) * 3)
    # Require sustained energy, not just a loud click in a padded VAD segment.
    return int(active.sum()) >= 12 and float(active.mean()) >= 0.1
