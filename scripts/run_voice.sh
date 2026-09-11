#!/bin/zsh
set -euo pipefail
SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
cd "$PROJECT_DIR"
export HF_HUB_OFFLINE=1
export PYTHONPATH="$PROJECT_DIR/backend"
exec .voice-venv/bin/python -m uvicorn voice.server:app --host 127.0.0.1 --port "${ARK_VOICE_PORT:-8766}" --workers 1 --ws-max-size 16384 --ws-max-queue 8
