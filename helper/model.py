"""Model loading and transcription helpers for the ASR helper server."""

import logging
import time
import wave

from mlx_audio.stt.utils import load_model
from mlx_audio.stt.generate import generate_transcription


logger = logging.getLogger("asr-helper")


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

        t0 = time.perf_counter()
        result = generate_transcription(self._model, audio_path)
        transcribe_time = time.perf_counter() - t0

        audio_duration = self._get_wav_duration(audio_path)
        transcript = result.text.strip() if hasattr(result, "text") else result.get("text", "").strip()

        return transcript, transcribe_time, audio_duration

    def _get_wav_duration(self, audio_path: str) -> float:
        """Get duration in seconds using stdlib wave. Returns 0.0 on error."""
        try:
            with wave.open(audio_path) as wf:
                return wf.getnframes() / wf.getframerate()
        except Exception:
            return 0.0