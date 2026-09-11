#!/bin/zsh
set -euo pipefail
SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
cd "$PROJECT_DIR"
if [[ ! -x .voice-venv/bin/python ]]; then
  uv venv .voice-venv --python backend/.venv/bin/python
fi
uv pip sync --python .voice-venv/bin/python backend/requirements-voice.lock
.voice-venv/bin/python scripts/prepare_voice_models.py
