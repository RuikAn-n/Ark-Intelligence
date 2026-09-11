#!/usr/bin/env python3
"""Download public model assets, pin HF revisions and record SHA256 checksums."""
import hashlib
import json
import ssl
import tarfile
import urllib.request
from pathlib import Path

import certifi
from huggingface_hub import HfApi, snapshot_download

ROOT = Path(__file__).resolve().parents[1]
DEST = ROOT / '.voice-models'
KWS = 'sherpa-onnx-kws-zipformer-zh-en-3M-2025-12-20'


def download(url, path):
    if path.is_file():
        return
    print(f'Downloading {path.name}', flush=True)
    with urllib.request.urlopen(url, context=ssl.create_default_context(cafile=certifi.where()), timeout=120) as response:
        part = path.with_suffix(path.suffix + '.part')
        with part.open('wb') as out:
            while block := response.read(1024 * 1024):
                out.write(block)
        part.replace(path)


def main():
    DEST.mkdir(exist_ok=True)
    manifest_path = DEST / 'manifest.json'
    lock_path = ROOT / 'backend/configs/voice-models.lock.json'
    locked = json.loads(lock_path.read_text()) if lock_path.exists() else {}
    manifest = dict(locked) if locked else (json.loads(manifest_path.read_text()) if manifest_path.exists() else {})
    for name, repo in [('asr', 'mlx-community/Qwen3-ASR-0.6B-8bit'), ('tts', 'mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-8bit')]:
        info = HfApi().model_info(repo, revision=manifest.get(name, {}).get('revision', 'main'))
        manifest[name] = {'repo': repo, 'revision': info.sha, 'license': (info.card_data or {}).get('license')}
        manifest_path.write_text(json.dumps(manifest, indent=2))
        print(f'{name}: {repo}@{info.sha}', flush=True)
        snapshot_download(repo, revision=info.sha, local_dir=DEST / name)
    archive = DEST / f'{KWS}.tar.bz2'
    download(f'https://github.com/k2-fsa/sherpa-onnx/releases/download/kws-models/{KWS}.tar.bz2', archive)
    if not (DEST / KWS).exists():
        with tarfile.open(archive) as package:
            package.extractall(DEST, filter='data')
    download('https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx', DEST / 'silero_vad.onnx')
    # Use the model's own English pronunciation lexicon, not guessed token IDs.
    lexicon = {}
    for line in (DEST / KWS / 'en.phone').read_text().splitlines():
        parts = line.split()
        lexicon[parts[0]] = parts[1:]
    tokens = []
    for word in ['HEY', 'SOPHIE']:
        phones = lexicon.get(word) or lexicon.get(word.lower())
        if not phones:
            raise RuntimeError(f'{word} missing from model lexicon')
        tokens.extend(phones)
    vocabulary = {line.split()[0] for line in (DEST / KWS / 'tokens.txt').read_text().splitlines()}
    if not set(tokens) <= vocabulary:
        raise RuntimeError('Wake phrase has out-of-vocabulary phones')
    (DEST / 'hey-sophie.txt').write_text(' '.join(tokens) + ' @HEY_SOPHIE\n')
    manifest['checksums'] = {}
    for path in sorted(DEST.rglob('*')):
        if path.is_file() and '.cache' not in path.parts and path != manifest_path:
            with path.open('rb') as handle:
                manifest['checksums'][str(path.relative_to(DEST))] = hashlib.file_digest(handle, 'sha256').hexdigest()
    for name, checksum in locked.get('checksums', {}).items():
        if manifest['checksums'].get(name) != checksum:
            raise RuntimeError(f'Model asset checksum mismatch: {name}')
    manifest_path.write_text(json.dumps(manifest, indent=2))
    print('Models ready; revisions and checksums saved to .voice-models/manifest.json', flush=True)


if __name__ == '__main__':
    main()
