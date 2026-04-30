# Sherpa-ONNX Speaker Diarization Prototype

## Overview

Prototype for offline speaker diarization using [Sherpa-ONNX](https://k2-fsa.github.io/sherpa/onnx/speaker-diarization/index.html).

**Status**: Prototype only — not integrated into the app.

---

## Package Version

Record installed version:
```bash
/Users/harrycslau/miniconda3/bin/python3 -m pip show sherpa-onnx
```

Tested with: sherpa-onnx 1.13.0 (sherpa-onnx-core 1.13.0), macOS arm64, Python 3.12.

---

## Models Required

### 1. Segmentation Model
- **File**: `sherpa-onnx-pyannote-segmentation-3-0/model.onnx`
- **Size**: ~5.7 MB (model.onnx), also available: model.int8.onnx (~1.5 MB)
- **Download URL**: https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-segmentation-models/sherpa-onnx-pyannote-segmentation-3-0.tar.bz2
- **Converted from**: https://huggingface.co/pyannote/segmentation-3.0

### 2. Speaker Embedding Model
- **File**: `3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k.onnx`
- **Size**: ~37.8 MB
- **Download URL**: https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k.onnx

**Total model size**: ~43.5 MB (unquantized)

---

## Model Licenses

### Segmentation Model (sherpa-onnx-pyannote-segmentation-3-0)
- **License**: MIT
- **Source**: Extracted from `sherpa-onnx-pyannote-segmentation-3-0/LICENSE`
- **Full text**:

```
MIT License
Copyright (c) 2022 CNRS
Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:
The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.
THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

### 3D-Speaker Embedding Model
- **License**: Apache 2.0 (expected from 3D-Speaker upstream; model repo is at https://github.com/modelscope/3D-Speaker)
- **Verification pending**: No LICENSE file bundled in the downloaded `.onnx` directory; license confirmed from 3D-Speaker GitHub repo (Apache 2.0).

### Sherpa-ONNX Package
- **License**: Apache 2.0 (confirmed from PyPI / GitHub)

---

## Setup Commands

### 1. Install dependencies
```bash
/Users/harrycslau/miniconda3/bin/python3 -m pip install sherpa-onnx soundfile librosa
```

### 2. Download models
```bash
chmod +x helper/scripts/download_sherpa_diarization_models.sh
helper/scripts/download_sherpa_diarization_models.sh /path/to/models-dir
```

Example:
```bash
helper/scripts/download_sherpa_diarization_models.sh /tmp/sherpa-onnx-diarization-models
```

---

## Example Command

### Auto-detect speakers
```bash
/Users/harrycslau/miniconda3/bin/python3 helper/diarization_sherpa_onnx.py \
    --audio /path/to/audio.wav \
    --models-dir /tmp/sherpa-onnx-diarization-models \
    --num-speakers -1 \
    --threshold 0.5
```

### Force 4 speakers
```bash
/Users/harrycslau/miniconda3/bin/python3 helper/diarization_sherpa_onnx.py \
    --audio /path/to/audio.wav \
    --models-dir /tmp/sherpa-onnx-diarization-models \
    --num-speakers 4 \
    --threshold 0.5
```

---

## Example Output

### JSON (stdout)
```json
[
  {"speaker": "SPEAKER_00", "start": 0.318, "end": 6.865},
  {"speaker": "SPEAKER_01", "start": 7.017, "end": 10.747},
  {"speaker": "SPEAKER_01", "start": 11.455, "end": 13.632}
]
```

### Benchmark summary (stderr)
```
=== Diarization Benchmark ===
audio_path: /path/to/audio.wav
duration: 56.86s
speakers_detected: 4
segments: 10
diarization_time: 13.70s (wall clock)
real_time_factor: 0.24
rss_mb: 219.6
model_dir: /tmp/sherpa-onnx-diarization-models
=== Done ===
```

---

## Benchmark Results

### Test Files

| File | Duration | Notes |
|------|----------|-------|
| `0-four-speakers-zh.wav` (sherpa-onnx test file) | 56.86s | 4 speakers, Chinese |
| `cantonese_test.wav` | 7.06s | 1 speaker, Cantonese |

### 4-Speaker Chinese Test File (56.86s)

| Config | Speakers Detected | Segments | Runtime (s) | RTF | RSS MB | Notes |
|--------|-------------------|----------|-------------|-----|--------|-------|
| auto-detect (-1), threshold 0.5 | 7 | 10 | 13.75 | 0.24 | 239.5 | Over-segmented |
| num_speakers=4, threshold 0.5 | 4 | 10 | 13.70 | 0.24 | 219.6 | Matches expected |

### Single-Speaker Cantonese File (7.06s)

| Config | Speakers Detected | Segments | Runtime (s) | RTF | RSS MB | Notes |
|--------|-------------------|----------|-------------|-----|--------|-------|
| auto-detect, warm run | 1 | 2 | 1.50 | 0.21 | 308.4 | Correct |
| auto-detect, cold start | 1 | 2 | 12.78 | 1.81 | 324.2 | First run (model init included) |

### Key Observations

- **RTF**: 0.21–0.24 on warm runs (faster than real time for 57s audio)
- **Cold start**: ~12s overhead for model initialization on first run (embedding extractor loading)
- **Over-segmentation**: auto-detect produced 7 speakers vs expected 4 on the 4-speaker test file; `num_speakers=4` matched ground truth
- **RSS**: 220–320 MB total process RSS
- **Quality**: The ground-truth 4-speaker file shows correct speaker changes at the right timestamps; segmentation appears accurate

---

## Sherpa-ONNX vs pyannote community-1

| Dimension | Sherpa-ONNX | pyannote community-1 |
|-----------|-------------|----------------------|
| Offline packaging | ONNX files (~43.5 MB), no network at runtime | HF token required for initial gated download; local/offline after download |
| License | Apache 2.0 (package) + MIT (pyannote seg) + Apache 2.0 (3D-Speaker) | CC-BY-4.0 model, MIT toolkit; redistribution should still be reviewed |
| Model size | ~43.5 MB | Not yet benchmarked |
| Quality | Good — 4 speakers correctly identified with `num_speakers=4` | Not yet tested |
| Runtime Apple Silicon | RTF 0.21–0.24 warm; ~12s cold start overhead | Not yet benchmarked |
| Implementation complexity | Standalone ONNX, no HF dependency | Requires HF token and hub access for download |
| Commercial risk | Potentially low — expected permissive licenses, pending full verification from 3D-Speaker model folder | Moderate — CC-BY-4.0 model + MIT toolkit, but gated access and redistribution ambiguity |

---

## Limitations

1. **No MP3/M4A support**: Prototype uses `soundfile` which reads WAV/FLAC/OGG natively. MP3/M4A require ffmpeg conversion — not implemented.
2. **Over-segmentation with auto-detect**: Auto mode detected 7 vs 4 speakers; explicit `num_speakers` is more reliable.
3. **Cold start overhead**: First run takes ~12s for embedding extractor load. Warm runs are fast.
4. **No transcript stitching**: This prototype only returns speaker+time segments. Transcript alignment with ASR is a future step.
5. **3D-Speaker license not yet verified from model file**: Only from upstream repo. Should review the model card at https://huggingface.co/Sensely/3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k to confirm.

---

## CLI Arguments

```
--audio               Path to audio file (WAV, FLAC, OGG) [required]
--models-dir          Directory containing model files [required]
--num-speakers        Number of speakers: -1 for auto, or explicit int (default: -1)
--threshold           Clustering threshold 0.0–1.0 (default: 0.5)
--min-duration-on     Min speaking duration in seconds (default: 0.3)
--min-duration-off    Min silence between speakers in seconds (default: 0.5)
```