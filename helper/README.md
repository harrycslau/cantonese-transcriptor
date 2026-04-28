# ASR Spike — Milestone 1

Verify that `mlx-community/GLM-ASR-Nano-2512-4bit` runs locally on Apple Silicon
and produces Cantonese-English transcription results.

## Setup

```bash
pip install -r requirements.txt
```

`mlx-audio` and its dependency `mlx` will be installed. On first run the model
is automatically downloaded from Hugging Face Hub and cached locally.

## Run

```bash
python transcribe.py <path_to_audio.wav>
# Example:
python transcribe.py ../audio/cantonese_test.wav
```

## Offline test

After the model is cached, verify offline operation:

```bash
HF_HUB_OFFLINE=1 python transcribe.py ../audio/cantonese_test.wav
```

## Output fields

| Field | Description |
|---|---|
| Audio duration | Length of the input WAV file in seconds |
| Load time | Seconds to load the model into MLX |
| Transcribe time | Seconds to run ASR inference |
| Real-time factor | transcribe_time / audio_duration; <1 means faster than real-time |

## Notes

- Audio input must be WAV for reliable duration measurement via stdlib `wave`.
- `mlx-audio` internals support more formats; the WAV restriction only affects
  the duration/timing display, not the transcription itself.
- Tested with `mlx-audio==0.2.9` and `mlx-community/GLM-ASR-Nano-2512-4bit`.