#!/usr/bin/env python3
"""
Benchmark: pyannote/speaker-diarization-community-1 on real audio.

CLI:
    /Users/harrycslau/miniconda3/envs/pyannote-bench/bin/python helper/diarization_pyannote.py \
        --audio /path/to/audio.wav \
        [--num-speakers N] \
        [--exclusive]

Output: JSON array to stdout, benchmark summary to stderr.
HF_TOKEN env var used only for initial model download — not logged or stored.
"""

import argparse
import json
import os
import sys
import time


def _rss_mb() -> float:
    """Return current process RSS in MB via ps."""
    try:
        import subprocess
        out = subprocess.check_output(
            ["ps", "-o", "rss=", "-p", str(os.getpid())], text=True
        )
        return int(out.strip()) / 1024
    except Exception:
        return 0.0


def _annotation_to_segments(annotation) -> list[dict]:
    """Convert pyannote Annotation to list of {speaker, start, end} dicts."""
    segments = []
    for turn, track, label in annotation.itertracks(yield_label=True):
        # Label may be "SPEAKER_00" or just "0" — preserve original
        speaker = str(label) if str(label).startswith("SPEAKER_") else f"SPEAKER_{int(label):02d}"
        segments.append({
            "speaker": speaker,
            "start": round(turn.start, 3),
            "end": round(turn.end, 3),
        })
    return segments


def _analyze_overlap(segments: list[dict], duration: float) -> dict:
    """Analyze overlap severity of diarization segments."""
    if not segments:
        return {"overlapping_pairs": 0, "overlap_pct": 0.0}

    # Build time ranges per speaker
    speaker_ranges = {}
    for seg in segments:
        spk = seg["speaker"]
        if spk not in speaker_ranges:
            speaker_ranges[spk] = []
        speaker_ranges[spk].append((seg["start"], seg["end"]))

    # Count overlapping pairs (two different speakers active at same time)
    overlapping_pairs = 0
    speakers = list(speaker_ranges.keys())
    for i, s1 in enumerate(speakers):
        for s2 in speakers[i+1:]:
            for r1 in speaker_ranges[s1]:
                for r2 in speaker_ranges[s2]:
                    # Check overlap: one starts before other ends and ends after other starts
                    if r1[0] < r2[1] and r1[1] > r2[0]:
                        overlapping_pairs += 1

    total_gaps = sum(
        1 for spk in speaker_ranges
        for r1, r2 in zip(speaker_ranges[spk], speaker_ranges[spk][1:])
        if r2[0] < r1[1]  # overlapping within same speaker
    )

    return {
        "overlapping_pairs": overlapping_pairs,
        "overlap_pct": round(overlapping_pairs / len(speakers), 3) if speakers else 0,
        "intra_speaker_overlaps": total_gaps,
    }


def _segment_stats(segments: list[dict]) -> dict:
    """Compute segment duration statistics."""
    if not segments:
        return {"under_1s": 0, "under_0.5s": 0, "min_dur": 0.0, "max_dur": 0.0}
    durations = [s["end"] - s["start"] for s in segments]
    return {
        "under_1s": sum(1 for d in durations if d < 1.0),
        "under_0.5s": sum(1 for d in durations if d < 0.5),
        "min_dur": round(min(durations), 3),
        "max_dur": round(max(durations), 3),
    }


class PyannoteDiarizer:
    def __init__(self, token: str | None = None):
        from pyannote.audio import Pipeline
        token = token or os.environ.get("HF_TOKEN")
        self._pipeline = Pipeline.from_pretrained(
            "pyannote/speaker-diarization-community-1",
            token=token,
        )

    def diarize(self, audio_path: str, num_speakers: int = -1,
                exclusive: bool = False) -> tuple[list[dict], dict]:
        """
        Run diarization on audio file.

        Returns (segments, meta) where meta has runtime, speaker count, etc.
        """
        t0 = time.perf_counter()
        rss_before = _rss_mb()

        # Build file argument (pyannote expects AudioFile dict or path)
        file_arg = audio_path

        # Call pipeline
        if num_speakers > 0:
            output = self._pipeline(file_arg, num_speakers=num_speakers)
        else:
            output = self._pipeline(file_arg)

        runtime = time.perf_counter() - t0
        rss_after = _rss_mb()

        # Get diarization result
        if exclusive and hasattr(output, "exclusive_speaker_diarization"):
            diar = output.exclusive_speaker_diarization
        elif hasattr(output, "speaker_diarization"):
            diar = output.speaker_diarization
        else:
            # Fallback: treat output itself as an Annotation
            diar = output

        segments = _annotation_to_segments(diar)
        speakers = len(diar.labels())

        meta = {
            "runtime_s": round(runtime, 2),
            "rss_mb": round(rss_after, 1),
            "speakers_detected": speakers,
            "segments": len(segments),
        }

        return segments, meta


def main():
    parser = argparse.ArgumentParser(
        description="pyannote speaker diarization benchmark"
    )
    parser.add_argument("--audio", required=True, help="Path to audio file")
    parser.add_argument(
        "--num-speakers", type=int, default=-1,
        help="Force exact N speakers (-1 for auto, default: -1)"
    )
    parser.add_argument(
        "--exclusive", action="store_true",
        help="Use exclusive_speaker_diarization output"
    )

    args = parser.parse_args()

    if not os.path.isfile(args.audio):
        print(json.dumps({"error": f"Audio file not found: {args.audio}"}))
        sys.exit(1)

    # Load pipeline (token from HF_TOKEN env, not logged)
    token = os.environ.get("HF_TOKEN")
    diarizer = PyannoteDiarizer(token=token)

    # Get audio duration
    import soundfile as sf
    audio_info = sf.info(args.audio)
    duration = audio_info.duration

    # Run diarization
    segments, meta = diarizer.diarize(
        args.audio,
        num_speakers=args.num_speakers,
        exclusive=args.exclusive,
    )

    rtf = meta["runtime_s"] / duration if duration > 0 else 0.0
    stats = _segment_stats(segments)
    overlap = _analyze_overlap(segments, duration)

    mode = "exclusive" if args.exclusive else "regular"
    num_spk_label = f"num_speakers={args.num_speakers}" if args.num_speakers > 0 else "auto"

    # Output JSON to stdout
    print(json.dumps(segments, indent=2))

    # Benchmark summary to stderr
    summary = (
        f"=== pyannote Diarization Benchmark ({mode}, {num_spk_label}) ===\n"
        f"audio_path: {args.audio}\n"
        f"duration: {duration:.2f}s\n"
        f"speakers_detected: {meta['speakers_detected']}\n"
        f"segments: {meta['segments']}\n"
        f"diarization_time: {meta['runtime_s']:.2f}s (wall clock)\n"
        f"real_time_factor: {rtf:.2f}\n"
        f"rss_mb: {meta['rss_mb']:.1f}\n"
        f"segments_under_1s: {stats['under_1s']}\n"
        f"segments_under_0.5s: {stats['under_0.5s']}\n"
        f"overlapping_speaker_pairs: {overlap['overlapping_pairs']}\n"
        f"overlap_pct: {overlap['overlap_pct']}\n"
        f"intra_speaker_overlaps: {overlap['intra_speaker_overlaps']}\n"
        f"min_segment_dur: {stats['min_dur']}s\n"
        f"max_segment_dur: {stats['max_dur']}s\n"
        f"=== Done ===\n"
    )
    sys.stderr.write(summary)


if __name__ == "__main__":
    main()