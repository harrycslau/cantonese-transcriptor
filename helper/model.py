"""Model loading and transcription helpers for the ASR helper server."""

import logging
import os
import shutil
import subprocess
import tempfile
import time
import wave
from pathlib import Path


logger = logging.getLogger("asr-helper")

FILE_CHUNK_DURATION_S = 15

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


def _rss_mb() -> float:
    """Return current process RSS in MB via ps, not peak RSS."""
    try:
        import subprocess
        out = subprocess.check_output(["ps", "-o", "rss=", "-p", str(os.getpid())], text=True)
        return int(out.strip()) / 1024
    except Exception:
        return 0.0


class SenseVoiceBackend:
    """
    FunASR SenseVoice backend.

    Loads FunAudioLLM/SenseVoiceSmall with VAD for long-audio segmentation.
    """

    def __init__(
        self,
        model_id: str = "FunAudioLLM/SenseVoiceSmall",
        language: str = "yue",
        device: str = "cpu",
        output_script: str = "traditional_hk",
    ):
        self._model = None
        self._model_id = model_id
        self._language = language
        self._device = device
        self._output_script = output_script
        self._load_time_s: float | None = None
        self._converter = self._build_converter(output_script)

    @property
    def load_time_s(self) -> float | None:
        return self._load_time_s

    def _build_converter(self, output_script: str):
        mapping = {
            "traditional_hk": "s2hk",
            "traditional_tw": "s2tw",
            "traditional": "s2t",
            "simplified": "t2s",
            "none": None,
        }
        if output_script not in mapping:
            raise RuntimeError(f"Unknown TRANSCRIPTOR_OUTPUT_SCRIPT: {output_script}")
        config = mapping[output_script]
        if config is None:
            return None
        try:
            from opencc import OpenCC
            return OpenCC(config)
        except ImportError:
            raise RuntimeError(
                f"OpenCC is required for TRANSCRIPTOR_OUTPUT_SCRIPT={output_script}. "
                "Install helper requirements: pip install -r requirements.txt"
            )

    def _convert_text(self, text: str) -> str:
        if not text or self._converter is None:
            return text
        return self._converter.convert(text)

    def load(self) -> None:
        from funasr import AutoModel
        logger.info(
            "Loading SenseVoice model=%s device=%s language=%s",
            self._model_id, self._device, self._language,
        )
        t0 = time.perf_counter()
        self._model = AutoModel(
            model=self._model_id,
            vad_model="fsmn-vad",
            vad_kwargs={"max_single_segment_time": 30000},
            hub="hf",
            device=self._device,
            disable_pbar=True,
        )
        self._load_time_s = time.perf_counter() - t0
        logger.info("SenseVoice loaded in %.2fs", self._load_time_s)

    def _extract_text(self, res) -> str:
        """Normalize FunASR generate() output to a single text string."""
        from funasr.utils.postprocess_utils import rich_transcription_postprocess
        if isinstance(res, list):
            parts = []
            for item in res:
                txt = item.get("text", "") if isinstance(item, dict) else str(item)
                parts.append(txt)
            processed = rich_transcription_postprocess("".join(parts))
        elif isinstance(res, dict):
            processed = rich_transcription_postprocess(res.get("text", ""))
        else:
            processed = rich_transcription_postprocess(str(res)) if res else ""
        return self._convert_text(processed)

    def transcribe(self, audio_path: str) -> tuple[str, float, float]:
        """Transcribe short audio (PTT/manual recording)."""
        if self._model is None:
            raise RuntimeError("Model not loaded. Call load() first.")
        t0 = time.perf_counter()
        audio_duration = self._get_audio_duration(audio_path)
        res = self._model.generate(
            input=audio_path,
            cache={},
            language=self._language,
            use_itn=True,
            batch_size_s=60,
            merge_vad=True,
            merge_length_s=15,
        )
        transcribe_time = time.perf_counter() - t0
        text = self._extract_text(res)
        return text.strip(), transcribe_time, audio_duration

    def transcribe_file(self, audio_path: str, job_id=None, progress_callback=None) -> tuple[str, float, float]:
        """
        Transcribe long audio using VAD segmentation.
        job_id and progress_callback are accepted for interface compatibility; not used by SenseVoice.
        Returns (transcript, transcribe_time_s, audio_duration_s).
        """
        if self._model is None:
            raise RuntimeError("Model not loaded. Call load() first.")
        t0 = time.perf_counter()
        audio_duration = self._get_audio_duration(audio_path)
        res = self._model.generate(
            input=audio_path,
            cache={},
            language=self._language,
            use_itn=True,
            batch_size_s=60,
            merge_vad=True,
            merge_length_s=15,
        )
        transcribe_time = time.perf_counter() - t0
        text = self._extract_text(res)
        return text.strip(), transcribe_time, audio_duration

    def _get_audio_duration(self, audio_path: str) -> float:
        ext = Path(audio_path).suffix.lower()
        if ext == ".wav":
            try:
                with wave.open(audio_path) as wf:
                    return wf.getnframes() / wf.getframerate()
            except Exception:
                pass
        try:
            import soundfile as sf
            info = sf.info(audio_path)
            return info.frames / info.samplerate
        except Exception:
            return 0.0


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
        from mlx_audio.stt.utils import load_model
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
        from mlx_audio.stt.generate import generate_transcription
        if self._model is None:
            raise RuntimeError("Model not loaded. Call load() first.")

        output_base = self._make_output_base(audio_path)
        t0 = time.perf_counter()
        try:
            result = generate_transcription(self._model, audio_path, output_path=output_base, max_tokens=48, verbose=False)
        finally:
            self._cleanup_output_files(output_base)
        transcribe_time = time.perf_counter() - t0

        audio_duration = self._get_audio_duration(audio_path)
        transcript = result.text.strip() if hasattr(result, "text") else result.get("text", "").strip()

        return transcript, transcribe_time, audio_duration

    def transcribe_file(self, audio_path: str, job_id=None, progress_callback=None) -> tuple[str, float, float]:
        """File transcription compatibility method — delegates to transcribe_chunked."""
        return self.transcribe_chunked(audio_path, job_id=job_id, progress_callback=progress_callback)

    def transcribe_chunked(self, audio_path: str, job_id: str = None,
                           progress_callback=None) -> tuple[str, float, float]:
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
            chunks = self._split_audio_chunks(audio_path, temp_dir, FILE_CHUNK_DURATION_S, job_id)
            if not chunks:
                raise RuntimeError(f"ffmpeg produced no chunks for {audio_path}")
            total = len(chunks)
            transcripts = []
            total_transcribe_time = 0.0
            for i, chunk_path in enumerate(chunks, start=1):
                chunk_dur = self._get_audio_duration(chunk_path)
                chunk_size = os.path.getsize(chunk_path)
                logger.info(
                    "chunk_transcribe_start job_id=%s chunk=%d/%d path=%s duration=%.2fs size=%d rss_mb=%.1f",
                    job_id, i, total, chunk_path, chunk_dur, chunk_size, _rss_mb(),
                )
                if progress_callback:
                    logger.info("progress_callback job_id=%s chunk=%d/%d stage=processing", job_id, i, total)
                    progress_callback(job_id, i, total, "processing")
                from mlx_audio.stt.generate import generate_transcription
                t0 = time.perf_counter()
                output_base = self._make_output_base(chunk_path)
                try:
                    result = generate_transcription(self._model, chunk_path,
                                                  output_path=output_base, max_tokens=48, verbose=False)
                except Exception as e:
                    raise RuntimeError(f"Chunk {i}/{total} failed: {e}") from e
                finally:
                    self._cleanup_output_files(output_base)
                chunk_time = time.perf_counter() - t0
                total_transcribe_time += chunk_time
                logger.info(
                    "chunk_transcribe_done job_id=%s chunk=%d/%d elapsed=%.2fs rss_mb=%.1f",
                    job_id, i, total, chunk_time, _rss_mb(),
                )
                transcript = result.text.strip() if hasattr(result, "text") else result.get("text", "").strip()
                del result  # release large result object before clearing caches
                transcripts.append(transcript)

                # Log MLX peak memory and clear caches
                try:
                    import mlx.core as mx
                    peak_gb = mx.get_peak_memory() / 1e9
                    logger.info("mlx_peak_memory_gb after chunk %d: %.2f", i, peak_gb)
                    mx.clear_cache()
                    after_cache_rss = _rss_mb()
                    logger.info("mlx_cache_cleared chunk %d rss_mb=%.1f", i, after_cache_rss)
                except Exception as e:
                    logger.info("mlx memory logging unavailable: %s", e)

                logger.info(
                    "chunk_done job_id=%s chunk=%d/%d duration=%.2fs",
                    job_id, i, total, chunk_time,
                )
                if progress_callback:
                    logger.info("progress_callback job_id=%s chunk=%d/%d stage=transcribed", job_id, i, total)
                    progress_callback(job_id, i, total, "transcribed")
            audio_duration = self._get_audio_duration(audio_path)
            return "\n\n".join(transcripts), total_transcribe_time, audio_duration
        finally:
            shutil.rmtree(temp_dir, ignore_errors=True)

    def _split_audio_chunks(self, audio_path: str, output_dir: str,
                            chunk_duration_s: int, job_id: str | None = None) -> list[str]:
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
        chunk_paths = [str(c) for c in chunks]
        source_dur = self._get_audio_duration(audio_path)
        logger.info(
            "chunking_summary job_id=%s chunks=%d chunk_duration_s=%d source_duration=%.2fs paths=%s",
            job_id, len(chunk_paths), chunk_duration_s, source_dur, chunk_paths[:5],
        )
        for cp in chunk_paths[:5]:
            size = os.path.getsize(cp)
            dur = self._get_audio_duration(cp)
            logger.info("  chunk %s size=%d bytes duration=%.2fs", cp, size, dur)
        return chunk_paths

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
