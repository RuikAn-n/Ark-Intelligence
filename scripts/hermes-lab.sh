#!/bin/bash
set -euo pipefail
ARK_PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ARK_PROJECT_ROOT/.hermes-lab/activate.sh"
cd "$ARK_HERMES_LAB/workspace"
case "${1:-chat}" in
  chat) shift || true; exec hermes chat --cli "$@" ;;
  ark) shift; exec hermes chat --cli -t ark_bridge --reasoning none "$@" ;;
  doctor) exec omh doctor ;;
  omh) shift; exec omh "$@" ;;
  test)
    cd "$ARK_HERMES_LAB/oh-my-hermes"
    python -m pytest -q tests/test_memory.py tests/test_memory_attention_tiers.py tests/test_model_routing.py
    exec omh memory recall-suite --revision f4b5bc2f4b95285669c121d396e598c1ad75ece8 --output "$ARK_HERMES_LAB/reports/recall-suite.json"
    ;;
  *) echo 'Usage: bash scripts/hermes-lab.sh [chat|ark|doctor|omh <args>|test]' >&2; exit 2 ;;
esac
