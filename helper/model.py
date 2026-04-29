"""Model loading and transcription helpers for the ASR helper server."""

import logging
import os
import shutil
import subprocess
import tempfile
import time
import wave
from pathlib import Path

from mlx_audio.stt.utils import load_model
from mlx_audio.stt.generate import generate_transcription


logger = logging.getLogger("asr-helper")

# Ordered by priority: env var → common homebrew paths → shutil.which
_FFMPEG_PATH: str | None = None

def _get_ffmpeg_path() -> str | None:
    """Resolve ffmpeg path, checking env var then common locations."""
    global _FFMPEG_PATH
    if _FFMPEG_PATH is not None:
        return _FFMPEG_PATH

    # 1. Env var override
    env_path = os.environ.get("TRANSCRIPTOR_FFMPEG_PATH")
    if env_path and os.path.isfile(env_path) and os.access(env_path, os.X_OK):
        _FFMPEG_PATH = env_path
        return _FFMPEG_PATH

    # 2. Common Homebrew paths (GUI apps often lack /opt/homebrew/bin in PATH)
    for prefix in ("/opt/homebrew/bin", "/usr/local/bin"):
        candidate = os.path.join(prefix, "ffmpeg")
        if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            _FFMPEG_PATH = candidate
            return _FFMPEG_PATH

    # 3. Fall back to PATH lookup
    _FFMPEG_PATH = shutil.which("ffmpeg")
    return _FFMPEG_PATH


class TranscriptionModel:
    """Wraps the MLX ASR model with load and transcribe timing."""

    def __init__(self, model_id: str = "mlx-community/GLM-ASR-Nano-2512-4bit"):
        self._model = None
        self._model_id = model_id
        self._load_time_s: float | None = None

    @property
    def load_time_s(self) -> float | None:
        return self._load_time_s

    def load(self) -> None:
        logger.info("Loading model %s...", self._model_id)
        t0 = time.perf_counter()
        self._model = load_model(self._model_id)
        self._load_time_s = time.perf_counter() - t0
        logger.info("Model loaded in %.2fs", self._load_time_s)

    def transcribe(self, audio_path: str) -> tuple[str, float, float]:
        """
        Transcribe an audio file.

        Returns (transcript, transcribe_time_s, audio_duration_s).
        """
        if self._model is None:
            raise RuntimeError("Model not loaded. Call load() first.")

        output_base = self._make_output_base(audio_path)
        t0 = time.perf_counter()
        try:
            result = generate_transcription(self._model, audio_path, output_path=output_base, verbose=False)
        finally:
            self._cleanup_output_files(output_base)
        transcribe_time = time.perf_counter() - t0

        audio_duration = self._get_audio_duration(audio_path)
        transcript = result.text.strip() if hasattr(result, "text") else result.get("text", "").strip()

        return transcript, transcribe_time, audio_duration

    def transcribe_chunked(self, audio_path: str, chunk_duration_s: int = 60,
                           job_id: str = None, progress_callback=None) -> tuple[str, float, float]:
        """
        Transcribe an audio file in chunks.

        progress_callback(chunk, total, stage) is called per chunk.
        Returns (concatenated_transcript, total_transcribe_time_s, audio_duration_s).
        """
        ffmpeg_path = _get_ffmpeg_path()
        if ffmpeg_path is None:
            raise RuntimeError(
                "Long file transcription requires ffmpeg. Set TRANSCRIPTOR_FFMPEG_PATH "
                "or ensure ffmpeg is in PATH."
            )

        temp_dir = tempfile.mkdtemp(prefix="transcriptor_chunks_")
        try:
            chunks = self._split_audio_chunks(audio_path, temp_dir, chunk_duration_s)
            if not chunks:
                raise RuntimeError(f"ffmpeg produced no chunks for {audio_path}")
            total = len(chunks)
            transcripts = []
            total_transcribe_time = 0.0
            for i, chunk_path in enumerate(chunks, start=1):
                logger.info(
                    "chunk_start job_id=%s chunk=%d/%d path=%s",
                    job_id, i, total, chunk_path,
                )
                if progress_callback:
                    progress_callback(job_id, i, total, "processing")
                t0 = time.perf_counter()
                output_base = self._make_output_base(chunk_path)
                try:
                    result = generate_transcription(self._model, chunk_path,
                                                  output_path=output_base, verbose=False)
                except Exception as e:
                    raise RuntimeError(f"Chunk {i}/{total} failed: {e}") from e
                finally:
                    self._cleanup_output_files(output_base)
                chunk_time = time.perf_counter() - t0
                total_transcribe_time += chunk_time
                transcript = result.text.strip() if hasattr(result, "text") else result.get("text", "").strip()
                transcripts.append(transcript)
                logger.info(
                    "chunk_done job_id=%s chunk=%d/%d duration=%.2fs",
                    job_id, i, total, chunk_time,
                )
                if progress_callback:
                    progress_callback(job_id, i, total, "transcribed")
            audio_duration = self._get_audio_duration(audio_path)
            return "\n\n".join(transcripts), total_transcribe_time, audio_duration
        finally:
            shutil.rmtree(temp_dir, ignore_errors=True)

    def _split_audio_chunks(self, audio_path: str, output_dir: str,
                            chunk_duration_s: int) -> list[str]:
        """Split audio into chunk_duration_s WAV files. Returns sorted list of chunk paths."""
        ffmpeg_path = _get_ffmpeg_path()
        if ffmpeg_path is None:
            raise RuntimeError(
                "Long file transcription requires ffmpeg. Set TRANSCRIPTOR_FFMPEG_PATH "
                "or ensure ffmpeg is in PATH."
            )
        cmd = [
            ffmpeg_path, "-y", "-i", audio_path,
            "-ac", "1", "-ar", "16000",
            "-f", "segment", "-segment_time", str(chunk_duration_s),
            "-c:a", "pcm_s16le",
            os.path.join(output_dir, "chunk_%05d.wav"),
        ]
        try:
            subprocess.run(cmd, check=True, capture_output=True, text=True)
        except subprocess.CalledProcessError as e:
            raise RuntimeError(f"ffmpeg split failed: {e.stderr}") from e
        chunks = sorted(Path(output_dir).glob("chunk_*.wav"))
        return [str(c) for c in chunks]

    def _get_audio_duration(self, audio_path: str) -> float:
        """Get duration in seconds. WAV uses stdlib; other formats try optional soundfile, else 0.0."""
        ext = Path(audio_path).suffix.lower()
        if ext == ".wav":
            return self._get_wav_duration(audio_path)
        try:
            import soundfile as sf
            info = sf.info(audio_path)
            return info.frames / info.samplerate
        except Exception:
            pass
        return 0.0

    def _get_wav_duration(self, audio_path: str) -> float:
        """Get duration in seconds using stdlib wave. Returns 0.0 on error."""
        try:
            with wave.open(audio_path) as wf:
                return wf.getnframes() / wf.getframerate()
        except Exception:
            return 0.0

    def _make_output_base(self, audio_path: str) -> str:
        """Return a writable base path for mlx-audio sidecar output files."""
        stem = Path(audio_path).stem or "audio"
        fd, path = tempfile.mkstemp(prefix=f"transcriptor_{stem}_", dir=tempfile.gettempdir())
        os.close(fd)
        os.unlink(path)
        return path

    def _cleanup_output_files(self, output_base: str) -> None:
        for suffix in (".txt", ".srt", ".vtt", ".json"):
            try:
                os.unlink(f"{output_base}{suffix}")
            except FileNotFoundError:
                pass
