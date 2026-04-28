#!/usr/bin/env python3
"""CLI script to transcribe a WAV audio file using GLM-ASR-Nano via mlx-audio."""

import argparse
import platform
import sys
import time
import wave

from mlx_audio.stt.utils import load_model
from mlx_audio.stt.generate import generate_transcription


def get_wav_duration(audio_path: str) -> float:
    """Return duration in seconds for a WAV file using stdlib wave."""
    with wave.open(audio_path) as wf:
        frames = wf.getnframes()
        rate = wf.getframerate()
        return frames / rate


def main() -> int:
    parser = argparse.ArgumentParser(description="Transcribe a WAV file with GLM-ASR-Nano-2512")
    parser.add_argument("audio", help="Path to a .wav audio file")
    args = parser.parse_args()

    if platform.machine() != "arm64":
        print(f"[WARNING] platform.machine() = {platform.machine()}, expected arm64 (Apple Silicon)")
        print("This script is designed for Apple Silicon. Results may be unpredictable on other platforms.")

    audio_path = args.audio
    audio_duration = get_wav_duration(audio_path)
    print(f"Loading model (first run will download from Hugging Face)...")
    load_start = time.perf_counter()
    model = load_model("mlx-community/GLM-ASR-Nano-2512-4bit")
    load_time = time.perf_counter() - load_start
    print(f"Model loaded in {load_time:.2f}s")

    print(f"Transcribing '{audio_path}' ({audio_duration:.2f}s audio)...")
    transcribe_start = time.perf_counter()
    result = generate_transcription(model, audio_path)
    transcribe_time = time.perf_counter() - transcribe_start

    if hasattr(result, "text"):
        transcript = result.text.strip()
    else:
        transcript = result.get("text", "").strip()
    rtf = transcribe_time / audio_duration if audio_duration > 0 else float("inf")

    print("\n--- Results ---")
    print(f"Transcript: {transcript}")
    print(f"\n--- Timing ---")
    print(f"Audio duration : {audio_duration:.3f}s")
    print(f"Load time      : {load_time:.2f}s")
    print(f"Transcribe time: {transcribe_time:.3f}s")
    print(f"Real-time factor: {rtf:.3f}x")
    return 0


if __name__ == "__main__":
    sys.exit(main())