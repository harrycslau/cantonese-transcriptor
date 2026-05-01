# cantonese-transcriptor
A cantonese transcriptor using ASR models which also support Mandarin and English

## Install the macOS App

The portable app is distributed as a small app bundle plus a setup script:

```text
Transcriptor-distribution/
  Transcriptor.app
  setup_transcriptor_env.sh
```

The app does not bundle Python, PyTorch, FunASR, or pyannote. Instead, the setup
script installs per-user Python environments under:

```text
~/Library/Application Support/Transcriptor/
```

This keeps the app bundle small and makes the Python dependencies repairable or
replaceable without rebuilding the app.

### Prerequisites

- macOS 13.0+ on Apple Silicon
- Python 3 available on the target Mac
- Internet access for the first dependency/model download
- Optional but recommended for file/diarization workflows: `ffmpeg`

Install `ffmpeg` with Homebrew if needed:

```bash
brew install ffmpeg
```

### Setup

From the distribution folder:

```bash
cd Transcriptor-distribution
./setup_transcriptor_env.sh
```

This creates the main helper environment:

```text
~/Library/Application Support/Transcriptor/envs/main
```

It installs the FunASR/SenseVoice dependencies and verifies the imports needed by
the helper.

### Optional Speaker Diarization

Speaker diarization uses pyannote and is optional. It is slower and can take
roughly real time or longer for long audio files.

Install the optional pyannote environment with:

```bash
./setup_transcriptor_env.sh --with-pyannote
```

This creates:

```text
~/Library/Application Support/Transcriptor/envs/pyannote
```

Do not embed or commit a Hugging Face token. If pyannote needs model access on
first use, run the app/helper once with `HF_TOKEN` set in your shell environment,
or pre-cache the model in the app support cache.

### Run

After setup:

```bash
open Transcriptor.app
```

Then select a WAV, MP3, or M4A file and transcribe. Speaker diarization can be
enabled from the app UI after the optional pyannote setup has completed.

### Installed Files

The app looks for helper dependencies in this order:

```text
TRANSCRIPTOR_PYTHON
~/Library/Application Support/Transcriptor/envs/main/bin/python
Transcriptor.app/Contents/Resources/python-env/bin/python
/usr/bin/python3
```

For pyannote:

```text
PYANNOTE_PYTHON
~/Library/Application Support/Transcriptor/envs/pyannote/bin/python
Transcriptor.app/Contents/Resources/pyannote-env/bin/python
```

Runtime caches are stored under:

```text
~/Library/Application Support/Transcriptor/cache
```

## Build a Distribution

From the repo root:

```bash
scripts/package_portable_app.sh
```

The output is:

```text
/private/tmp/cantonese-transcriptor-release/Transcriptor-distribution
```

Copy that distribution folder to another Mac, then run:

```bash
cd Transcriptor-distribution
./setup_transcriptor_env.sh
open Transcriptor.app
```

## Developer Build

For Xcode development:

```bash
cd macos
xcodegen generate
xcodebuild -scheme Transcriptor -configuration Debug -derivedDataPath /tmp/transcriptor-derived build
```

Or open `macos/Transcriptor.xcodeproj` in Xcode and press Run. The Xcode scheme
may provide development-only environment variables such as `TRANSCRIPTOR_PYTHON`,
`TRANSCRIPTOR_HELPER_PATH`, and `PYANNOTE_PYTHON`.
