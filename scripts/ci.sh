#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
if [ ! -d ".venv" ]; then
  python -m venv .venv
fi
if [ -x ".venv/bin/python" ]; then
  PY=".venv/bin/python"
else
  PY=".venv/Scripts/python.exe"
fi
"$PY" -m pip install -r requirements-dev.txt
"$PY" scripts/ci.py

