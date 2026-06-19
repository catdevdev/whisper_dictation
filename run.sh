#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV="$ROOT/venv-tts"
PYTHON_BIN="${PYTHON_BIN:-}"
VENV_READY=0
STAMP="$VENV/.requirements.stamp"
LOG_DIR="$HOME/.whisper_dictation"
RUN_LOG="$LOG_DIR/run.log"
MENU_HELPER="$ROOT/WhisperMenuBar.app"

mkdir -p "$LOG_DIR"
exec >> "$RUN_LOG" 2>&1
echo "[$(date '+%Y-%m-%d %H:%M:%S %z')] launcher start root=$ROOT"
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/opt/homebrew/opt/python@3.13/bin:/opt/homebrew/opt/python@3.12/bin:/opt/homebrew/opt/python@3.11/bin:/opt/homebrew/opt/python@3.10/bin:${PATH:-}"

if [[ -x "$VENV/bin/python" ]]; then
  if "$VENV/bin/python" - <<'PY' >/dev/null 2>&1
import sys
raise SystemExit(0 if (3, 10) <= sys.version_info[:2] < (3, 14) else 1)
PY
  then
    VENV_READY=1
  else
    rm -rf "$VENV"
  fi
fi

if [[ "$VENV_READY" -ne 1 && -z "$PYTHON_BIN" ]]; then
  for candidate in python3.13 python3.12 python3.11 python3.10; do
    if command -v "$candidate" >/dev/null 2>&1; then
      PYTHON_BIN="$(command -v "$candidate")"
      break
    fi
  done
fi

if [[ "$VENV_READY" -ne 1 && -z "$PYTHON_BIN" ]]; then
  echo "Need Python 3.10-3.13 for local TTS. Install python3.13 or set PYTHON_BIN=/path/to/python." >&2
  exit 1
fi

echo "[$(date '+%Y-%m-%d %H:%M:%S %z')] python=${PYTHON_BIN:-$VENV/bin/python} venv=$VENV ready=$VENV_READY"

if [[ ! -d "$VENV" ]]; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S %z')] creating venv"
  "$PYTHON_BIN" -m venv "$VENV"
fi

if [[ ! -f "$STAMP" || "$ROOT/requirements.txt" -nt "$STAMP" ]]; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S %z')] installing requirements"
  "$VENV/bin/python" -m pip install --upgrade pip
  "$VENV/bin/python" -m pip install -r "$ROOT/requirements.txt"
  touch "$STAMP"
fi

if [[ -d "$MENU_HELPER" ]]; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S %z')] launching menu helper=$MENU_HELPER"
  /usr/bin/open -g "$MENU_HELPER" || true
else
  echo "[$(date '+%Y-%m-%d %H:%M:%S %z')] menu helper missing=$MENU_HELPER"
fi

echo "[$(date '+%Y-%m-%d %H:%M:%S %z')] launching app"
exec "$VENV/bin/python" "$ROOT/main.py"
