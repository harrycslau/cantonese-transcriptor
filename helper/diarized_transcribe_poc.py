#!/usr/bin/env python3
"""
Proof-of-concept: diarized transcription combining pyannote segments with SenseVoice.

Step A (pyannote-bench env, separate):
    python helper/diarization_pyannote.py \
        --audio /tmp/cantonese_3speakers_16k.wav \
        --num-speakers 3 --exclusive \
        > /tmp/cantonese_3speakers_segments.json

Step B (main helper env, this script):
    /Users/harrycslau/miniconda3/bin/python3 helper/diarized_transcribe_poc.py \
        --audio /tmp/cantonese_3speakers_16k.wav \
        --segments-json /tmp/cantonese_3speakers_segments.json
"""

import argparse
import json
import os
import socket
import subprocess
import sys
import tempfile
import time


SOCKET_PATH = "/tmp/cantonese-transcriptor.sock"
MIN_SEGMENT_DURATION = 0.3
GAP_THRESHOLD = 0.5


def _rss_mb() -> float:
    try:
        out = subprocess.check_output(["ps", "-o", "rss=", "-p", str(os.getpid())], text=True)
        return int(out.strip()) / 1024
    except Exception:
        return 0.0


def _get_ffmpeg_path() -> str | None:
    # TRANSCRIPTOR_FFMPEG_PATH env var takes priority
    env_path = os.environ.get("TRANSCRIPTOR_FFMPEG_PATH")
    if env_path and os.path.isfile(env_path) and os.access(env_path, os.X_OK):
        return env_path
    # Homebrew prefixes
    for prefix in ("/opt/homebrew/bin", "/usr/local/bin"):
        candidate = os.path.join(prefix, "ffmpeg")
        if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    # PATH
    import shutil
    return shutil.which("ffmpeg")


def _ping_helper() -> bool:
    """Check if helper server is running."""
    fd = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    fd.settimeout(2.0)
    try:
        fd.connect(SOCKET_PATH)
        ping_req = b'{"jsonrpc":"2.0","method":"ping","id":0}\n'
        fd.sendall(ping_req)
        resp = fd.recv(256)
        data = json.loads(resp.decode("utf-8").strip())
        return data.get("result", {}).get("status") == "ok"
    except Exception:
        return False
    finally:
        fd.close()


def _send_transcribe(audio_path: str, job_id: str, timeout: int = 300) -> tuple[str, float]:
    """Send transcribe request to helper, return (transcript, transcribe_time)."""
    fd = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    fd.settimeout(float(timeout))
    try:
        fd.connect(SOCKET_PATH)
        req = {
            "jsonrpc": "2.0",
            "method": "transcribe",
            "params": {"audio_path": audio_path, "job_id": job_id},
            "id": 1,
        }
        fd.sendall((json.dumps(req) + "\n").encode("utf-8"))
        resp = b""
        while True:
            chunk = fd.recv(4096)
            if not chunk:
                break
            resp += chunk
            if b"\n" in resp:
                break
        data = json.loads(resp.decode("utf-8").strip())
        if "error" in data:
            raise RuntimeError(f"Helper error: {data['error']['message']}")
        result = data.get("result", {})
        return result.get("transcript", ""), result.get("timing", {}).get("transcribe_time_s", 0.0)
    finally:
        fd.close()


def merge_segments(segments: list[dict], gap_threshold: float = 0.5) -> list[dict]:
    if not segments:
        return []
    merged = [segments[0].copy()]
    for seg in segments[1:]:
        last = merged[-1]
        gap = seg["start"] - last["end"]
        if seg["speaker"] == last["speaker"] and 0 <= gap <= gap_threshold:
            last["end"] = seg["end"]
        elif gap < 0:
            sys.stderr.write(f"Error: overlapping segments detected (should not happen with exclusive): {last} vs {seg}\n")
            sys.exit(1)
        else:
            merged.append(seg.copy())
    return merged


def main():
    parser = argparse.ArgumentParser(description="Diarized transcription POC")
    parser.add_argument("--audio", required=True, help="Path to 16kHz mono WAV")
    parser.add_argument("--segments-json", required=True, help="Path to diarization segments JSON")
    args = parser.parse_args()

    if not os.path.isfile(args.audio):
        print(json.dumps({"error": f"Audio file not found: {args.audio}"}))
        sys.exit(1)

    # Load segments
    with open(args.segments_json) as f:
        segments = json.load(f)

    original_count = len(segments)

    # Drop short segments
    segments = [s for s in segments if (s["end"] - s["start"]) >= MIN_SEGMENT_DURATION]
    dropped_count = original_count - len(segments)
    sys.stderr.write(f"Original segments: {original_count}, dropped (<{MIN_SEGMENT_DURATION}s): {dropped_count}, remaining: {len(segments)}\n")

    # Merge adjacent same-speaker segments
    segments = merge_segments(segments, GAP_THRESHOLD)
    sys.stderr.write(f"After merging: {len(segments)} segments\n")

    # Check helper is running
    if not _ping_helper():
        sys.stderr.write("Error: Helper server not running. Start the app first.\n")
        sys.exit(1)

    # Get audio duration
    try:
        import wave
        with wave.open(args.audio) as wf:
            audio_duration = wf.getnframes() / wf.getframerate()
    except Exception:
        audio_duration = 0.0

    rss_before = _rss_mb()
    t0 = time.perf_counter()

    # Get ffmpeg
    ffmpeg = _get_ffmpeg_path()
    if ffmpeg is None:
        sys.stderr.write("Error: ffmpeg not found. Set TRANSCRIPTOR_FFMPEG_PATH or ensure it's in PATH.\n")
        sys.exit(1)

    results = []
    total_asr_time = 0.0
    total_slice_time = 0.0

    with tempfile.TemporaryDirectory(prefix="diarized_poc_") as tmpdir:
        for i, seg in enumerate(segments):
            duration = seg["end"] - seg["start"]
            slice_path = os.path.join(tmpdir, f"slice_{i:03d}.wav")

            # Extract slice
            t_slice = time.perf_counter()
            cmd = [
                ffmpeg, "-y",
                "-ss", str(seg["start"]), "-to", str(seg["end"]),
                "-i", args.audio,
                "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le",
                slice_path,
            ]
            subprocess.run(cmd, check=True, capture_output=True, text=True)
            slice_time = time.perf_counter() - t_slice
            total_slice_time += slice_time

            # Transcribe
            job_id = f"diarized-poc-{i}"
            try:
                transcript, asr_time = _send_transcribe(slice_path, job_id)
            except Exception as e:
                sys.stderr.write(f"Error transcribing segment {i}: {e}\n")
                transcript = f"[error: {e}]"
                asr_time = 0.0

            total_asr_time += asr_time

            results.append({
                "speaker": seg["speaker"],
                "start": seg["start"],
                "end": seg["end"],
                "duration": round(duration, 3),
                "transcript": transcript,
                "asr_time_s": round(asr_time, 2),
            })

            sys.stderr.write(f"  [{i+1}/{len(segments)}] {seg['speaker']} [{duration:.2f}s, {asr_time:.2f}s ASR] {transcript[:50]}...\n")

    total_time = time.perf_counter() - t0
    rss_after = _rss_mb()
    rtf = total_time / audio_duration if audio_duration > 0 else 0.0

    # Output JSON to stdout
    print(json.dumps(results, indent=2, ensure_ascii=False))

    # Summary to stderr
    sys.stderr.write(f"\n=== Diarized Transcription POC ===\n")
    sys.stderr.write(f"audio: {args.audio}\n")
    sys.stderr.write(f"duration: {audio_duration:.2f}s\n")
    sys.stderr.write(f"original_segments: {original_count}\n")
    sys.stderr.write(f"dropped_short: {dropped_count}\n")
    sys.stderr.write(f"merged_segments: {len(segments)}\n")
    sys.stderr.write(f"total_time: {total_time:.2f}s\n")
    sys.stderr.write(f"total_slice_time: {total_slice_time:.2f}s\n")
    sys.stderr.write(f"total_asr_time: {total_asr_time:.2f}s\n")
    sys.stderr.write(f"rtf: {rtf:.2f}\n")
    sys.stderr.write(f"rss_mb: {rss_after:.1f}\n")
    sys.stderr.write(f"=== Done ===\n")

    # Readable transcript to stderr
    sys.stderr.write("\n=== Speaker-labeled Transcript ===\n")
    for r in results:
        sys.stderr.write(f"{r['speaker']}: {r['transcript']}\n")


if __name__ == "__main__":
    main()