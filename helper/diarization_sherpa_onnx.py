#!/usr/bin/env python3
"""
Prototype: Sherpa-ONNX offline speaker diarization.

CLI:
    /Users/harrycslau/miniconda3/bin/python3 helper/diarization_sherpa_onnx.py \
        --audio /path/to/audio.wav \
        --models-dir /path/to/sherpa-onnx-diarization-models \
        [--num-speakers -1] \
        [--threshold 0.5] \
        [--min-duration-on 0.3] \
        [--min-duration-off 0.5]

Output: JSON array to stdout, benchmark summary to stderr.
"""

import argparse
import json
import os
import soundfile as sf
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


class SherpaDiarizer:
    def __init__(
        self,
        models_dir: str,
        num_speakers: int = -1,
        threshold: float = 0.5,
        min_duration_on: float = 0.3,
        min_duration_off: float = 0.5,
    ):
        import sherpa_onnx

        seg_path = os.path.join(
            models_dir, "sherpa-onnx-pyannote-segmentation-3-0", "model.onnx"
        )
        emb_path = os.path.join(
            models_dir, "3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k.onnx"
        )

        if not os.path.isfile(seg_path):
            raise RuntimeError(f"Segmentation model not found: {seg_path}")
        if not os.path.isfile(emb_path):
            raise RuntimeError(f"Embedding model not found: {emb_path}")

        pyannote_config = sherpa_onnx.OfflineSpeakerSegmentationPyannoteModelConfig(
            model=seg_path
        )
        seg_config = sherpa_onnx.OfflineSpeakerSegmentationModelConfig(
            pyannote=pyannote_config,
        )
        emb_config = sherpa_onnx.SpeakerEmbeddingExtractorConfig(model=emb_path)
        clustering_config = sherpa_onnx.FastClusteringConfig(
            num_clusters=num_speakers, threshold=threshold
        )

        config = sherpa_onnx.OfflineSpeakerDiarizationConfig(
            segmentation=seg_config,
            embedding=emb_config,
            clustering=clustering_config,
            min_duration_on=min_duration_on,
            min_duration_off=min_duration_off,
        )

        if not config.validate():
            raise RuntimeError(
                f"Config validation failed. Check model files in: {models_dir}"
            )

        self._diarizer = sherpa_onnx.OfflineSpeakerDiarization(config)
        self._sample_rate = self._diarizer.sample_rate

    @property
    def sample_rate(self) -> int:
        return self._sample_rate

    def diarize(self, audio_path: str) -> list[dict]:
        """
        Returns list of dicts:
            {"speaker": "SPEAKER_00", "start": 0.12, "end": 3.84}
        """
        import librosa

        audio, sr = sf.read(audio_path, dtype="float32", always_2d=True)
        audio = audio[:, 0]  # use first channel only

        # Resample to expected rate if needed
        if sr != self._sample_rate:
            audio = librosa.resample(
                audio, orig_sr=sr, target_sr=self._sample_rate
            )

        result = self._diarizer.process(audio).sort_by_start_time()

        segments = []
        for seg in result:
            segments.append({
                "speaker": f"SPEAKER_{seg.speaker:02d}",
                "start": round(seg.start, 3),
                "end": round(seg.end, 3),
            })
        return segments


def main():
    parser = argparse.ArgumentParser(
        description="Sherpa-ONNX offline speaker diarization prototype"
    )
    parser.add_argument(
        "--audio", required=True, help="Path to audio file (WAV, FLAC, OGG)"
    )
    parser.add_argument(
        "--models-dir",
        required=True,
        help="Directory containing diarization model files",
    )
    parser.add_argument(
        "--num-speakers",
        type=int,
        default=-1,
        help="Number of speakers (-1 for auto-detect, default: -1)",
    )
    parser.add_argument(
        "--threshold",
        type=float,
        default=0.5,
        help="Clustering threshold (default: 0.5)",
    )
    parser.add_argument(
        "--min-duration-on",
        type=float,
        default=0.3,
        help="Min speaking duration (default: 0.3s)",
    )
    parser.add_argument(
        "--min-duration-off",
        type=float,
        default=0.5,
        help="Min silence between speakers (default: 0.5s)",
    )

    args = parser.parse_args()

    if not os.path.isfile(args.audio):
        print(json.dumps({"error": f"Audio file not found: {args.audio}"}))
        sys.exit(1)

    rss_before = _rss_mb()

    diarizer = SherpaDiarizer(
        models_dir=args.models_dir,
        num_speakers=args.num_speakers,
        threshold=args.threshold,
        min_duration_on=args.min_duration_on,
        min_duration_off=args.min_duration_off,
    )

    import soundfile as sf

    audio_info = sf.info(args.audio)
    audio_duration = audio_info.duration

    t0 = time.perf_counter()
    segments = diarizer.diarize(args.audio)
    diarization_time = time.perf_counter() - t0

    rss_after = _rss_mb()

    rtf = diarization_time / audio_duration if audio_duration > 0 else 0.0

    # Output JSON to stdout
    print(json.dumps(segments, indent=2))

    # Benchmark summary to stderr
    summary = (
        f"=== Diarization Benchmark ===\n"
        f"audio_path: {args.audio}\n"
        f"duration: {audio_duration:.2f}s\n"
        f"speakers_detected: {len(set(s['speaker'] for s in segments))}\n"
        f"segments: {len(segments)}\n"
        f"diarization_time: {diarization_time:.2f}s (wall clock)\n"
        f"real_time_factor: {rtf:.2f}\n"
        f"rss_mb: {rss_after:.1f}\n"
        f"model_dir: {args.models_dir}\n"
        f"=== Done ===\n"
    )
    sys.stderr.write(summary)


if __name__ == "__main__":
    main()