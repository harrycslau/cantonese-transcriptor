# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build Commands

### macOS App
```bash
cd macos
xcodegen generate
xcodebuild -scheme Transcriptor -configuration Debug -derivedDataPath /tmp/transcriptor-derived build
```

### ASR Helper (Python server)
```bash
cd helper
pip install -r requirements.txt
python3 server.py &
```

## Architecture

Two-process design: a macOS SwiftUI app communicates with a Python ASR helper via Unix domain socket.

### macOS App (`macos/Transcriptor/`)
- **HelperManager.swift**: Manages Python helper lifecycle (starts/stops helper subprocess, checks health via ping). Helper path configured via `TRANSCRIPTOR_HELPER_PATH` env var in Xcode scheme.
- **TranscriptionManager.swift**: State machine for transcription workflow (idle → fileSelected/recording → transcribing → success/error). Coordinates with UnixSocketClient and AudioRecorder.
- **UnixSocketClient.swift**: JSON-RPC 2.0 client over Unix socket (`/tmp/cantonese-transcriptor.sock`). Sends `transcribe` and `ping` requests.
- **AudioRecorder.swift**: Records microphone audio to temporary WAV files.
- **HotkeyManager.swift**: Global hotkey listener for push-to-talk (Left Control key). Requires Accessibility permission.
- **ClipboardManager.swift**: Saves/restores clipboard and sends paste commands to insert transcript into target apps.

### Python Helper (`helper/`)
- **server.py**: Persistent ASR server. Loads mlx-audio model on startup, handles JSON-RPC 2.0 requests over NDJSON. Emits "ready" to stderr when prepared.
- **model.py**: Wraps mlx-whisper model loading and transcription.
- **protocol.py**: JSON-RPC response builders (success, error, ping).

## Communication Protocol

Unix socket at `/tmp/cantonese-transcriptor.sock`, NDJSON framing, JSON-RPC 2.0:
- `transcribe(audio_path, job_id)` → returns `{transcript, timing: {model_load_time_s, transcribe_time_s, audio_duration_s, real_time_factor}}`
- `ping()` → returns `{version: "2.0"}`

Error codes: -32600 (Invalid request), -32601 (Method not found), -32602 (Invalid params), -32603 (Internal error).

## Runtime Requirements

- macOS 13.0+ Apple Silicon
- XcodeGen (`brew install xcodegen`)
- Python dependencies: `pip install -r requirements.txt` in helper/
- Accessibility permission needed for: (1) global hotkey, (2) inserting transcript into target apps via clipboard paste
- Microphone permission for audio recording
