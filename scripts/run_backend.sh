#!/bin/zsh
set -euo pipefail
SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
ARK_PORT=${ARK_PORT:-8765}
if lsof -nP -iTCP:${ARK_PORT} -sTCP:LISTEN >/dev/null 2>&1; then
  echo "Ark 后端无法启动：127.0.0.1:${ARK_PORT} 已被占用。可使用 ARK_PORT=其他端口启动，并为应用设置相同的 ARK_API_URL。" >&2
  lsof -nP -iTCP:${ARK_PORT} -sTCP:LISTEN >&2
  exit 48
fi
cd "$PROJECT_DIR/backend"
exec .venv/bin/uvicorn api.server:app --host 127.0.0.1 --port "$ARK_PORT" --workers 1
