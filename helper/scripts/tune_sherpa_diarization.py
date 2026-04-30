#!/usr/bin/env python3
"""
Parameter tuning grid for Sherpa-ONNX speaker diarization.
Runs a matrix of (threshold, min_duration_on, min_duration_off) combinations
on a given audio file and prints results as a table.
"""
import subprocess
import sys

# Grid
thresholds = [0.5, 0.6, 0.7, 0.8]
min_duration_on_values = [0.3, 0.5]
min_duration_off_values = [0.5, 0.8, 1.0]

audio_path = sys.argv[1] if len(sys.argv) > 1 else "/tmp/0-four-speakers-zh.wav"
models_dir = sys.argv[2] if len(sys.argv) > 2 else "/tmp/sherpa-onnx-diarization-models"
interpreter = "/Users/harrycslau/miniconda3/bin/python3"
script = "/Users/harrycslau/Documents/GitRepositories/cantonese-transcriptor/helper/diarization_sherpa_onnx.py"

print(f"Audio: {audio_path}")
print(f"Models: {models_dir}")
print()
header = f"{'threshold':>10} {'min_on':>7} {'min_off':>7} {'speakers':>8} {'segments':>8} {'runtime':>8} {'rtf':>6}"
print(header)
print("-" * len(header))

for thresh in thresholds:
    for min_on in min_duration_on_values:
        for min_off in min_duration_off_values:
            result = subprocess.run(
                [
                    interpreter, script,
                    "--audio", audio_path,
                    "--models-dir", models_dir,
                    "--num-speakers", "-1",
                    "--threshold", str(thresh),
                    "--min-duration-on", str(min_on),
                    "--min-duration-off", str(min_off),
                ],
                capture_output=True,
                text=True,
            )
            lines = result.stderr.strip().split("\n")
            summary = {}
            for line in lines:
                if ": " in line and "===" not in line:
                    key, val = line.split(": ", 1)
                    summary[key.strip()] = val.strip()

            # Extract runtime and speakers
            rt = summary.get("diarization_time", "?").replace("s (wall clock)", "")
            rtf = summary.get("real_time_factor", "?")
            spks = summary.get("speakers_detected", "?")
            segs = summary.get("segments", "?")
            dur = summary.get("duration", "?")
            rss = summary.get("rss_mb", "?")

            print(f"{thresh:>10} {min_on:>7} {min_off:>7} {spks:>8} {segs:>8} {rt:>8} {rtf:>6}  rss={rss}")

print()
print(f"Note: Expected 4 speakers in {audio_path}")