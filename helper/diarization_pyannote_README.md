# pyannote Speaker Diarization Prototype

## Overview

Prototype for offline speaker diarization using [pyannote/speaker-diarization-community-1](https://huggingface.co/pyannote/speaker-diarization-community-1).

**Status**: Prototype — not integrated into the app.

---

## Package Version

```bash
/Users/harrycslau/miniconda3/envs/pyannote-bench/bin/python -m pip show pyannote.audio
```

Tested with: **pyannote-audio 4.0.4**, pyannote.metrics (bundled), pyannote.database (bundled), macOS arm64, Python 3.11.

> **Important**: `pyannote/speaker-diarization-community-1` is licensed **CC BY-NC 4.0**. This is a commercial blocker — the model cannot be used in commercial products without a separate licensing agreement with pyannote. Benchmark results below are from research/prototype use only.

---

## Model License

- **Model**: `pyannote/speaker-diarization-community-1`
- **License**: CC BY-NC 4.0
- **Commercial use**: **Not permitted** under CC BY-NC 4.0. Contact pyannote for commercial licensing.
- **Access**: Requires HuggingFace account and acceptance of the model card terms at https://huggingface.co/pyannote/speaker-diarization-community-1
- **HF_TOKEN**: Required for initial gated model download only. After download, the model is cached locally and no token is needed at runtime.

---

## Environment Setup

### pyannote-bench conda environment

```bash
/Users/harrycslau/miniconda3/bin/conda create -n pyannote-bench python=3.11 -y
/Users/harrycslau/miniconda3/envs/pyannote-bench/bin/python -m pip install -U pip
/Users/harrycslau/miniconda3/envs/pyannote-bench/bin/python -m pip install "lightning>=2.4"
/Users/harrycslau/miniconda3/envs/pyannote-bench/bin/python -m pip install "pyannote.audio==4.0.4"
```

### HF_TOKEN

Set your HuggingFace token as an environment variable before running the diarization script:

```bash
export HF_TOKEN="hf_your_token_here"
```

The token is used only for initial model download — not logged or stored.

---

## CLI Usage

```bash
/Users/harrycslau/miniconda3/envs/pyannote-bench/bin/python helper/diarization_pyannote.py \
    --audio /path/to/audio.wav \
    [--num-speakers N] \
    [--exclusive]
```

### Arguments

| Argument | Description | Default |
|----------|-------------|---------|
| `--audio` | Path to audio file (WAV/FLAC/OGG) | Required |
| `--num-speakers` | Force exact N speakers (-1 for auto) | -1 |
| `--exclusive` | Use exclusive_speaker_diarization output (recommended) | False |

### Output

- **stdout**: JSON array of `{speaker, start, end}` segments
- **stderr**: Benchmark summary

---

## Example

### Auto-detect speakers
```bash
/Users/harrycslau/miniconda3/envs/pyannote-bench/bin/python helper/diarization_pyannote.py \
    --audio /tmp/cantonese_3speakers_16k.wav \
    --num-speakers -1
```

### Force 3 speakers, exclusive mode (recommended)
```bash
/Users/harrycslau/miniconda3/envs/pyannote-bench/bin/python helper/diarization_pyannote.py \
    --audio /tmp/cantonese_3speakers_16k.wav \
    --num-speakers 3 \
    --exclusive \
    > /tmp/cantonese_3speakers_segments.json
```

> **Important**: Redirect stdout to a file to capture the JSON segments. Use `2>/dev/null` to suppress the benchmark summary on stderr, or `2>&1` to capture everything (then extract JSON from the file).

---

## Benchmark Results

### Test File

`cantonese_3speakers_16k.wav` — 187.15s, 3 speakers, Cantonese conversation.

### Regular vs Exclusive Mode

| Mode | Speakers Detected | Segments | Runtime (s) | RTF | RSS MB | Overlapping Pairs |
|------|-------------------|----------|-------------|-----|--------|-------------------|
| auto, regular | 3 | 65 | 182.77 | 0.98 | 959.9 | 12 |
| auto, exclusive | 3 | 35 | 177.20 | 0.95 | 958.3 | 0 |
| num_speakers=3, regular | 3 | 59 | 180.31 | 0.96 | 955.2 | 9 |
| num_speakers=3, exclusive | **3** | **35** | **175.14** | **0.94** | **957.9** | **0** |

### Key Observations

- **Exclusive mode** produces zero overlapping speaker pairs — all segments are sequential and non-overlapping
- **Regular mode** produces overlapping segments (multiple speakers active simultaneously), which complicates transcript alignment
- **Auto-detect** with exclusive mode correctly identifies 3 speakers
- **RTF**: ~0.94–0.98 (slightly slower than real time on 187s audio)
- **RSS**: ~960 MB (pyannote model is memory-intensive)
- **Quality**: Exclusive mode cleanly separates 3 speakers with correct sequential boundaries

### Why Exclusive Mode

The `exclusive_speaker_diarization` output from pyannote ensures each time point belongs to exactly one speaker, producing sequential non-overlapping segments. This is critical for:
1. Simpler transcript alignment (each segment maps to one speaker)
2. No ambiguity about who spoke when
3. Clean integration with ASR pipeline

---

## Comparison: pyannote vs Sherpa-ONNX

| Dimension | pyannote community-1 | Sherpa-ONNX |
|-----------|----------------------|-------------|
| Model license | CC BY-NC 4.0 (gated) | Apache 2.0 + MIT + Apache 2.0 |
| Offline packaging | HF cache, no network at runtime after download | ONNX files, fully offline |
| Auto-detect quality | Correct on 3-speaker test (exclusive mode) | Over-segmented (7–15 on 3-speaker files) |
| Overlapping segments | Exclusive mode eliminates them | Always present in regular output |
| Runtime (RTF) | 0.94–0.98 | 0.21–0.24 (warm) |
| Memory (RSS) | ~960 MB | ~220–320 MB |
| Model size | Not measured | ~43.5 MB |
| macOS Apple Silicon | Supported | Supported |
| Commercial risk | Moderate — CC BY-NC 4.0, gated access | Lower — permissive licenses |

**Recommendation**: pyannote exclusive mode is the quality winner. Sherpa-ONNX is faster and more memory-efficient but produces over-segmented results that require significant post-processing.

---

## Limitations

1. **Memory**: ~960 MB RSS — heavier than Sherpa-ONNX
2. **RTF**: ~0.94 — slightly slower than real time on 3-speaker audio
3. **CC BY-NC 4.0**: Gated model, commercial use requires separate licensing from pyannote
4. **No transcript**: This prototype only returns speaker+time segments. See `diarized_transcribe_poc.py` for combined diarization + transcription pipeline.
5. **Short segments**: Many segments < 0.5s — these are dropped by `diarized_transcribe_poc.py` (MIN_SEGMENT_DURATION = 0.3s)

---

## Pipeline: Diarization + Transcription

The full POC combining pyannote diarization with SenseVoice transcription is in `diarized_transcribe_poc.py`. It runs in two steps:

**Step A** (pyannote-bench env): Produce speaker segments
```bash
/Users/harrycslau/miniconda3/envs/pyannote-bench/bin/python helper/diarization_pyannote.py \
    --audio /tmp/cantonese_3speakers_16k.wav \
    --num-speakers 3 --exclusive \
    > /tmp/cantonese_3speakers_segments.json 2>/dev/null
```

**Step B** (main helper env, helper server must be running): Transcribe each segment
```bash
/Users/harrycslau/miniconda3/bin/python3 helper/diarized_transcribe_poc.py \
    --audio /tmp/cantonese_3speakers_16k.wav \
    --segments-json /tmp/cantonese_3speakers_segments.json
```

Output: JSON array of `{speaker, start, end, duration, transcript, asr_time_s}` to stdout, benchmark summary to stderr.
