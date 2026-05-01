#!/usr/bin/env bash
set -euo pipefail

# Resolve repo root from script location (repo layout: scripts/ is next to helper/).
# In a distribution folder the script sits next to Transcriptor.app, and
# requirements.txt lives inside the app bundle.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/../helper/requirements.txt" ]; then
  # Repo layout
  ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
  cd "$ROOT_DIR"
  REQUIREMENTS_PATH="$ROOT_DIR/helper/requirements.txt"
elif [ -f "$SCRIPT_DIR/Transcriptor.app/Contents/Resources/helper/requirements.txt" ]; then
  # Distribution layout
  REQUIREMENTS_PATH="$SCRIPT_DIR/Transcriptor.app/Contents/Resources/helper/requirements.txt"
else
  echo "Error: requirements.txt not found." >&2
  echo "  Looked in:" >&2
  echo "    $SCRIPT_DIR/../helper/requirements.txt (repo layout)" >&2
  echo "    $SCRIPT_DIR/Transcriptor.app/Contents/Resources/helper/requirements.txt (distribution layout)" >&2
  exit 1
fi

APP_SUPPORT="$HOME/Library/Application Support/Transcriptor"
MAIN_ENV="$APP_SUPPORT/envs/main"
PYANNOTE_ENV="$APP_SUPPORT/envs/pyannote"
CACHE_DIR="$APP_SUPPORT/cache"

WITH_PYANNOTE=0
FORCE=0

for arg in "$@"; do
  case $arg in
    --with-pyannote) WITH_PYANNOTE=1 ;;
    --force) FORCE=1 ;;
    *) echo "Unknown option: $arg" >&2; exit 1 ;;
  esac
done

echo "=== Transcriptor Environment Setup ==="
echo ""
echo "App support directory: $APP_SUPPORT"
echo ""

# ── helpers ────────────────────────────────────────────────────────────────────

ensure_dir() {
  mkdir -p "$1"
}

venv_exists() {
  [ -f "$1/bin/python" ]
}

# ── main env ───────────────────────────────────────────────────────────────────

echo "[Main environment]"

# Choose Python for main env: prefer Miniconda, then system python3
if [ -f "/Users/harrycslau/miniconda3/bin/python3" ]; then
  MAIN_PYTHON="/Users/harrycslau/miniconda3/bin/python3"
else
  MAIN_PYTHON="python3"
fi

if [ "$FORCE" = 1 ] && [ -d "$MAIN_ENV" ]; then
  echo "  Removing existing main env (--force)..."
  rm -rf "$MAIN_ENV"
fi

if venv_exists "$MAIN_ENV"; then
  echo "  Using existing env: $MAIN_ENV"
else
  echo "  Creating main env at: $MAIN_ENV (using $MAIN_PYTHON)"
  ensure_dir "$(dirname "$MAIN_ENV")"
  "$MAIN_PYTHON" -m venv "$MAIN_ENV"
  "$MAIN_ENV/bin/pip" install --upgrade pip setuptools wheel
  "$MAIN_ENV/bin/pip" install -r "$REQUIREMENTS_PATH"
fi

# Verify main env imports
if [ -f "$MAIN_ENV/bin/python" ]; then
  if PYTHONPATH="$(dirname "$REQUIREMENTS_PATH")" \
     "$MAIN_ENV/bin/python" -c \
       "import soundfile; import funasr; import torchaudio; import torch; import opencc; \
        from model import SenseVoiceBackend; print('OK')" >/dev/null 2>&1; then
    echo "  [soundfile, funasr, torchaudio, torch, opencc, SenseVoiceBackend] OK"
  else
    echo "  [soundfile, funasr, torchaudio, torch, opencc, SenseVoiceBackend] FAILED"
    PYTHONPATH="$(dirname "$REQUIREMENTS_PATH")" \
      "$MAIN_ENV/bin/python" -c \
        "import soundfile; import funasr; import torchaudio; import torch; import opencc; \
         from model import SenseVoiceBackend; print('OK')" >&2 || true
  fi
else
  echo "  [main env python] NOT FOUND"
fi

echo ""
echo "Main env Python: $MAIN_ENV/bin/python"
echo "Cache directory: $CACHE_DIR"

# ── pyannote env ────────────────────────────────────────────────────────────────

if [ "$WITH_PYANNOTE" = 1 ]; then
  echo ""
  echo "[Pyannote environment]"

  # Choose Python: prefer Miniconda Python 3.11, else fall back
  PYANNOTE_PYTHON=""
  for candidate in \
    "/Users/harrycslau/miniconda3/envs/pyannote311/bin/python" \
    "/Users/harrycslau/miniconda3/bin/python3.11" \
    "/Users/harrycslau/miniconda3/bin/python3" \
    "/usr/bin/python3.11" \
    "/usr/bin/python3"; do
    if [ -f "$candidate" ]; then
      PYANNOTE_PYTHON="$candidate"
      break
    fi
  done
  if [ -z "$PYANNOTE_PYTHON" ]; then
    PYANNOTE_PYTHON="python3"
  fi

  if [ "$FORCE" = 1 ] && [ -d "$PYANNOTE_ENV" ]; then
    echo "  Removing existing pyannote env (--force)..."
    rm -rf "$PYANNOTE_ENV"
  fi

  if venv_exists "$PYANNOTE_ENV"; then
    echo "  Using existing env: $PYANNOTE_ENV"
  else
    echo "  Creating pyannote env at: $PYANNOTE_ENV (using $PYANNOTE_PYTHON)"
    ensure_dir "$(dirname "$PYANNOTE_ENV")"
    "$PYANNOTE_PYTHON" -m venv "$PYANNOTE_ENV"
    "$PYANNOTE_ENV/bin/pip" install --upgrade pip setuptools wheel
    "$PYANNOTE_ENV/bin/pip" install pyannote.audio
  fi

  # Verify pyannote import
  if [ -f "$PYANNOTE_ENV/bin/python" ]; then
    if "$PYANNOTE_ENV/bin/python" -c \
        "from pyannote.audio import Pipeline; print('OK')" >/dev/null 2>&1; then
      echo "  [pyannote.audio Pipeline] OK"
    else
      echo "  [pyannote.audio Pipeline] FAILED"
      "$PYANNOTE_ENV/bin/python" -c \
        "from pyannote.audio import Pipeline; print('OK')" >&2 || true
    fi
  else
    echo "  [pyannote env python] NOT FOUND"
  fi

  echo ""
  echo "Pyannote env Python: $PYANNOTE_ENV/bin/python"
  echo ""
  echo "pyannote installed. Diarization is optional and can take about real-time or slower for long files."
  echo "For first model download, run the app or helper with HF_TOKEN set, e.g.:"
  echo "  HF_TOKEN=... open Transcriptor.app"
else
  echo ""
  echo "[Pyannote environment] not installed; pass --with-pyannote to install"
fi

echo ""
echo "=== Setup complete ==="