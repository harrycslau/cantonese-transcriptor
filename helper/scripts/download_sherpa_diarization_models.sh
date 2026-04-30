#!/bin/bash
#
# Download Sherpa-ONNX speaker diarization model files.
# Usage: helper/scripts/download_sherpa_diarization_models.sh [/path/to/models-dir]
#
# Models downloaded:
#   - sherpa-onnx-pyannote-segmentation-3-0 (from k2-fsa release)
#   - 3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k.onnx (from k2-fsa release)
#
set -e

MODELS_DIR="${1:-./sherpa-onnx-diarization-models}"
mkdir -p "$MODELS_DIR"

# Detect available downloader
if command -v wget &> /dev/null; then
    DOWNLOAD() { wget -q -O "$2" "$1"; }
elif command -v curl &> /dev/null; then
    DOWNLOAD() { curl -sL -o "$2" "$1"; }
else
    echo "Error: neither wget nor curl found. Please install wget or curl." >&2
    exit 1
fi

echo "Downloading models to: $MODELS_DIR"

# Segmentation model (tar.bz2 → extract → cleanup)
echo "Downloading pyannote segmentation model..."
DOWNLOAD \
    "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-segmentation-models/sherpa-onnx-pyannote-segmentation-3-0.tar.bz2" \
    "$MODELS_DIR/sherpa-onnx-pyannote-segmentation-3-0.tar.bz2"

echo "Extracting..."
tar xvf "$MODELS_DIR/sherpa-onnx-pyannote-segmentation-3-0.tar.bz2" -C "$MODELS_DIR"
rm "$MODELS_DIR/sherpa-onnx-pyannote-segmentation-3-0.tar.bz2"

# Embedding model (single .onnx file)
echo "Downloading 3D-Speaker embedding model..."
DOWNLOAD \
    "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k.onnx" \
    "$MODELS_DIR/3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k.onnx"

echo ""
echo "=== Download complete ==="
echo "Models directory: $MODELS_DIR"
echo ""
echo "Directory contents:"
ls -la "$MODELS_DIR"
echo ""
echo "Segmentation model:"
ls -la "$MODELS_DIR/sherpa-onnx-pyannote-segmentation-3-0/"
echo ""
echo "Embedding model:"
ls -la "$MODELS_DIR/3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k.onnx"