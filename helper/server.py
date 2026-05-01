#!/usr/bin/env python3
"""Persistent ASR helper server — Unix socket, NDJSON, JSON-RPC 2.0."""

import json
import logging
import os
import signal
import socket
import subprocess
import sys
import tempfile
import time
import uuid
from pathlib import Path

# Ensure helper dir is on path for imports
sys.path.insert(0, str(Path(__file__).parent))

from model import TranscriptionModel, SenseVoiceBackend
import protocol


_ASR_BACKEND = os.environ.get("TRANSCRIPTOR_ASR_BACKEND", "sensevoice")
_MLX_MODEL_ID = os.environ.get("TRANSCRIPTOR_MLX_MODEL_ID", "mlx-community/GLM-ASR-Nano-2512-4bit")
_SENSEVOICE_MODEL = os.environ.get("TRANSCRIPTOR_SENSEVOICE_MODEL", "FunAudioLLM/SenseVoiceSmall")
_SENSEVOICE_LANGUAGE = os.environ.get("TRANSCRIPTOR_SENSEVOICE_LANGUAGE", "yue")
_SENSEVOICE_DEVICE = os.environ.get("TRANSCRIPTOR_SENSEVOICE_DEVICE", "cpu")
_SENSEVOICE_OUTPUT_SCRIPT = os.environ.get("TRANSCRIPTOR_OUTPUT_SCRIPT", "traditional_hk")


SOCKET_PATH = "/tmp/cantonese-transcriptor.sock"
LOG_PATH = "/tmp/cantonese-transcriptor.log"

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    handlers=[logging.FileHandler(LOG_PATH)],
)
logger = logging.getLogger("asr-helper")


class Server:
    def __init__(self):
        if _ASR_BACKEND == "sensevoice":
            self._model = SenseVoiceBackend(
                model_id=_SENSEVOICE_MODEL,
                language=_SENSEVOICE_LANGUAGE,
                device=_SENSEVOICE_DEVICE,
                output_script=_SENSEVOICE_OUTPUT_SCRIPT,
            )
            self._backend_name = "SenseVoice"
        elif _ASR_BACKEND == "mlx":
            self._model = TranscriptionModel(model_id=_MLX_MODEL_ID)
            self._backend_name = "MLX-GLM"
        else:
            raise RuntimeError(f"Unknown TRANSCRIPTOR_ASR_BACKEND: {_ASR_BACKEND}")
        self._running = False
        self._socket: socket.socket | None = None
        self._in_progress = False

    def load_model(self) -> float:
        self._model.load()
        return self._model.load_time_s

    def start(self):
        if os.path.exists(SOCKET_PATH):
            os.unlink(SOCKET_PATH)
        self._socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self._socket.bind(SOCKET_PATH)
        self._socket.listen(1)
        self._running = True
        logger.info("Listening on %s", SOCKET_PATH)

    def stop(self):
        logger.info("Shutting down...")
        self._running = False
        if self._socket:
            self._socket.close()
        if os.path.exists(SOCKET_PATH):
            os.unlink(SOCKET_PATH)
        logger.info("Server stopped")

    def run(self):
        self._socket.settimeout(1.0)  # wake periodically to check _running
        while self._running:
            try:
                conn, _ = self._socket.accept()
                self._handle_connection(conn)
            except socket.timeout:
                continue  # check _running and loop
            except OSError:
                break

    def _handle_connection(self, conn: socket.socket):
        """Handle one persistent connection. Process requests until disconnect."""
        conn.settimeout(1.0)  # wake periodically to check _running
        try:
            buf = ""
            while self._running:
                try:
                    data = conn.recv(4096)
                    if not data:
                        break
                    buf += data.decode("utf-8")
                    while "\n" in buf:
                        line, buf = buf.split("\n", 1)
                        if line.strip():
                            self._process_request(conn, line)
                except socket.timeout:
                    continue  # check _running and keep connection open
                except OSError:
                    break
        except Exception as e:
            logger.error("Connection error: %s", e)
        finally:
            conn.close()

    def _process_request(self, conn: socket.socket, line: str):
        try:
            data = json.loads(line)
        except json.JSONDecodeError:
            resp = protocol.build_error_response(-32600, "Invalid JSON", None, None)
            conn.sendall((json.dumps(resp) + "\n").encode("utf-8"))
            return

        if data.get("jsonrpc") != "2.0":
            resp = protocol.build_error_response(-32600, "Missing or invalid jsonrpc version", None, data.get("id"))
            conn.sendall((json.dumps(resp) + "\n").encode("utf-8"))
            return

        method = data.get("method")
        if method == "ping":
            resp = protocol.build_ping_response(data.get("id"))
            conn.sendall((json.dumps(resp) + "\n").encode("utf-8"))
            return

        if method == "transcribe":
            self._handle_transcribe(conn, data)
            return

        if method == "transcribe_file_chunked":
            self._handle_transcribe_file_chunked(conn, data)
            return

        if method == "transcribe_with_diarization":
            self._handle_transcribe_with_diarization(conn, data)
            return

        resp = protocol.build_error_response(-32601, f"Unknown method: {method}", None, data.get("id"))
        conn.sendall((json.dumps(resp) + "\n").encode("utf-8"))

    def _validate_audio_request(self, data: dict) -> tuple[bool, dict | None, dict | None]:
        """Returns (ok, validated_params, error_response). On ok, error_response is None."""
        params = data.get("params")
        rid = data.get("id")
        if not isinstance(params, dict):
            return False, None, protocol.build_error_response(-32602, "params must be a JSON object", None, rid)
        audio_path = params.get("audio_path")
        job_id = params.get("job_id") or str(uuid.uuid4())
        if not isinstance(audio_path, str) or not audio_path:
            return False, None, protocol.build_error_response(-32602, "params.audio_path must be a non-empty string", job_id, rid)
        if not os.path.isabs(audio_path):
            return False, None, protocol.build_error_response(-32602, "params.audio_path must be an absolute path", job_id, rid)
        ok, path_err = protocol.validate_audio_path(audio_path)
        if not ok:
            return False, None, protocol.build_error_response(-32602, path_err, job_id, rid)
        return True, {"audio_path": audio_path, "job_id": job_id}, None

    def _handle_transcribe(self, conn: socket.socket, data: dict):
        ok, params, err_resp = self._validate_audio_request(data)
        if not ok:
            conn.sendall((json.dumps(err_resp) + "\n").encode("utf-8"))
            return

        audio_path = params["audio_path"]
        job_id = params["job_id"]

        try:
            self._in_progress = True
            logger.info(
                "Transcription started job_id=%s audio_path=%s size=%s",
                job_id,
                audio_path,
                os.path.getsize(audio_path) if os.path.exists(audio_path) else None,
            )
            transcript, transcribe_time, audio_duration = self._model.transcribe(audio_path)
            logger.info(
                "Transcription finished job_id=%s transcribe_time=%.2f audio_duration=%.2f",
                job_id,
                transcribe_time,
                audio_duration,
            )
            rtf = transcribe_time / audio_duration if audio_duration > 0 else 0.0
            timing = {
                "model_load_time_s": self._model.load_time_s or 0.0,
                "transcribe_time_s": transcribe_time,
                "audio_duration_s": audio_duration,
                "real_time_factor": rtf,
            }
            resp = protocol.build_success_response(job_id, transcript, timing, data.get("id"))
            conn.sendall((json.dumps(resp) + "\n").encode("utf-8"))
        except Exception as e:
            logger.exception(
                "Transcription failed job_id=%s audio_path=%s exists=%s size=%s",
                job_id,
                audio_path,
                os.path.exists(audio_path),
                os.path.getsize(audio_path) if os.path.exists(audio_path) else None,
            )
            resp = protocol.build_error_response(-32603, str(e), job_id, data.get("id"))
            conn.sendall((json.dumps(resp) + "\n").encode("utf-8"))
        finally:
            self._in_progress = False

    def _handle_transcribe_file_chunked(self, conn: socket.socket, data: dict):
        ok, params, err_resp = self._validate_audio_request(data)
        if not ok:
            conn.sendall((json.dumps(err_resp) + "\n").encode("utf-8"))
            return

        audio_path = params["audio_path"]
        job_id = params["job_id"]

        def progress_callback(jid, chunk, total, stage):
            notify = protocol.build_progress_notification(jid, chunk, total, stage)
            conn.sendall((json.dumps(notify) + "\n").encode("utf-8"))

        try:
            self._in_progress = True
            transcript, transcribe_time, audio_duration = self._model.transcribe_file(
                audio_path, job_id=job_id, progress_callback=progress_callback
            )
            rtf = transcribe_time / audio_duration if audio_duration > 0 else 0.0
            timing = {
                "model_load_time_s": self._model.load_time_s or 0.0,
                "transcribe_time_s": transcribe_time,
                "audio_duration_s": audio_duration,
                "real_time_factor": rtf,
            }
            resp = protocol.build_success_response(job_id, transcript, timing, data.get("id"))
            conn.sendall((json.dumps(resp) + "\n").encode("utf-8"))
        except Exception as e:
            logger.exception(
                "File transcription failed job_id=%s audio_path=%s",
                job_id, audio_path,
            )
            resp = protocol.build_error_response(-32603, str(e), job_id, data.get("id"))
            conn.sendall((json.dumps(resp) + "\n").encode("utf-8"))
        finally:
            self._in_progress = False

    def _handle_transcribe_with_diarization(self, conn: socket.socket, data: dict):
        ok, params, err_resp = self._validate_audio_request(data)
        if not ok:
            conn.sendall((json.dumps(err_resp) + "\n").encode("utf-8"))
            return

        audio_path = params["audio_path"]
        job_id = params["job_id"]
        num_speakers = params.get("num_speakers", -1)

        # Validate num_speakers
        if not isinstance(num_speakers, int) or not (-1 <= num_speakers <= 10) or num_speakers == 0:
            resp = protocol.build_error_response(
                -32602,
                "num_speakers must be -1 (auto) or an integer 1..10",
                job_id,
                data.get("id"),
            )
            conn.sendall((json.dumps(resp) + "\n").encode("utf-8"))
            return

        # Check PYANNOTE_PYTHON env var
        pyannote_python = os.environ.get("PYANNOTE_PYTHON")
        if not pyannote_python:
            resp = protocol.build_error_response(
                -32603,
                "pyannote not configured. Set PYANNOTE_PYTHON env var to the "
                "pyannote-bench interpreter. Run "
                "HF_TOKEN=... PYANNOTE_PYTHON=... "
                "helper/diarization_pyannote.py --audio ... once to cache the model.",
                job_id,
                data.get("id"),
            )
            conn.sendall((json.dumps(resp) + "\n").encode("utf-8"))
            return

        # Get audio duration from original file for timeout calculation
        audio_duration_s = self._model._get_audio_duration(audio_path)
        diarize_timeout = max(600, int(audio_duration_s * 2))

        try:
            t0 = time.perf_counter()

            with tempfile.TemporaryDirectory(prefix="diarized_") as tmpdir:
                t_prepare = time.perf_counter()
                diarization_audio_path = self._prepare_audio_for_diarization(
                    audio_path, tmpdir
                )
                audio_prep_time_s = time.perf_counter() - t_prepare

                # Stage 1: diarize
                self._stream_progress(conn, job_id, stage="diarizing", chunk=0, total=1)
                t_diarize = time.perf_counter()
                segments, diarization_err = self._run_pyannote_diarization(
                    pyannote_python, diarization_audio_path, num_speakers,
                    timeout=diarize_timeout,
                )
                diarization_time_s = time.perf_counter() - t_diarize

                if segments is None:
                    resp = protocol.build_error_response(
                        -32603,
                        f"pyannote diarization failed: {diarization_err[:500]}",
                        job_id,
                        data.get("id"),
                    )
                    conn.sendall((json.dumps(resp) + "\n").encode("utf-8"))
                    return

            # Post-process: drop short, merge gaps
                segments = self._drop_short_segments(segments, min_duration=0.3)
                segments = self._merge_segments(segments, gap_threshold=0.5)

                # Stage 2: slice + transcribe each segment. Slice from the same
                # normalized WAV that pyannote saw, so timestamps stay aligned.
                total_slice_time_s = 0.0
                total_asr_model_time_s = 0.0
                results = []
                t_segment_loop = time.perf_counter()
                for i, seg in enumerate(segments):
                    self._stream_progress(
                        conn, job_id, stage="transcribing", chunk=i + 1, total=len(segments)
                    )
                    t_slice = time.perf_counter()
                    slice_path = self._slice_audio(
                        diarization_audio_path, seg["start"], seg["end"], tmpdir
                    )
                    total_slice_time_s += time.perf_counter() - t_slice
                    try:
                        transcript, model_time_s, audio_dur = self._model.transcribe(slice_path)
                        total_asr_model_time_s += model_time_s
                    finally:
                        if os.path.exists(slice_path):
                            os.unlink(slice_path)
                    results.append({
                        **seg,
                        "duration": round(seg["end"] - seg["start"], 3),
                        "transcript": transcript,
                    })

                segment_loop_time_s = time.perf_counter() - t_segment_loop
                total_time_s = time.perf_counter() - t0
                audio_duration_s = self._model._get_audio_duration(diarization_audio_path)

            formatted = self._format_diarized_transcript(results)

            timing = {
                "audio_prep_time_s": round(audio_prep_time_s, 3),
                "diarization_time_s": round(diarization_time_s, 3),
                "slice_time_s": round(total_slice_time_s, 3),
                "asr_model_time_s": round(total_asr_model_time_s, 3),
                "segment_loop_time_s": round(segment_loop_time_s, 3),
                "total_time_s": round(total_time_s, 3),
                "audio_duration_s": round(audio_duration_s, 3),
                "real_time_factor": round(total_time_s / audio_duration_s, 3)
                if audio_duration_s > 0
                else 0.0,
            }

            resp = protocol.build_success_response_diarized(
                job_id, formatted, results, False, timing, data.get("id")
            )
            conn.sendall((json.dumps(resp) + "\n").encode("utf-8"))

        except Exception as e:
            logger.exception("Diarized transcription failed job_id=%s", job_id)
            resp = protocol.build_error_response(
                -32603, str(e), job_id, data.get("id")
            )
            conn.sendall((json.dumps(resp) + "\n").encode("utf-8"))

    def _run_pyannote_diarization(
        self, python_path: str, audio_path: str, num_speakers: int, timeout: int
    ) -> tuple[list[dict] | None, str]:
        """Run pyannote diarization subprocess. Returns (segments, stderr_or_empty)."""
        script_dir = os.path.dirname(os.path.abspath(__file__))
        diarize_script = os.path.join(script_dir, "diarization_pyannote.py")
        cmd = [
            python_path,
            diarize_script,
            "--audio",
            audio_path,
            "--num-speakers",
            str(num_speakers),
            "--exclusive",
        ]
        try:
            proc = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                timeout=timeout,
            )
        except subprocess.TimeoutExpired:
            return None, f"diarization timed out after {timeout}s"
        except Exception as e:
            return None, str(e)

        if proc.returncode != 0:
            return None, proc.stderr[:500]

        try:
            segments = json.loads(proc.stdout)
            return segments, ""
        except json.JSONDecodeError as e:
            return None, f"failed to parse segment JSON: {e}"

    def _stream_progress(
        self, conn: socket.socket, job_id: str, stage: str, chunk: int, total: int
    ):
        notify = protocol.build_progress_notification(job_id, chunk, total, stage)
        conn.sendall((json.dumps(notify) + "\n").encode("utf-8"))

    def _slice_audio(
        self, audio_path: str, start: float, end: float, tmpdir: str
    ) -> str:
        """Slice audio to a temp WAV. Returns absolute path."""
        ffmpeg = self._get_ffmpeg_path()
        if ffmpeg is None:
            raise RuntimeError("ffmpeg not found")
        out_path = os.path.join(tmpdir, f"slice_{start:.3f}_{end:.3f}.wav")
        cmd = [
            ffmpeg,
            "-y",
            "-ss",
            str(start),
            "-to",
            str(end),
            "-i",
            audio_path,
            "-ac",
            "1",
            "-ar",
            "16000",
            "-c:a",
            "pcm_s16le",
            out_path,
        ]
        subprocess.run(cmd, check=True, capture_output=True, text=True)
        return out_path

    def _prepare_audio_for_diarization(self, audio_path: str, tmpdir: str) -> str:
        """Normalize input to 16 kHz mono WAV for stable pyannote chunking."""
        ffmpeg = self._get_ffmpeg_path()
        if ffmpeg is None:
            raise RuntimeError("ffmpeg not found")
        out_path = os.path.join(tmpdir, "diarization_input.wav")
        cmd = [
            ffmpeg,
            "-y",
            "-i",
            audio_path,
            "-ac",
            "1",
            "-ar",
            "16000",
            "-c:a",
            "pcm_s16le",
            out_path,
        ]
        subprocess.run(cmd, check=True, capture_output=True, text=True)
        return out_path

    def _get_ffmpeg_path(self) -> str | None:
        """Find ffmpeg: TRANSCRIPTOR_FFMPEG_PATH > Homebrew > PATH."""
        env_path = os.environ.get("TRANSCRIPTOR_FFMPEG_PATH")
        if env_path and os.path.isfile(env_path) and os.access(env_path, os.X_OK):
            return env_path
        for prefix in ("/opt/homebrew/bin", "/usr/local/bin"):
            candidate = os.path.join(prefix, "ffmpeg")
            if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
                return candidate
        import shutil
        return shutil.which("ffmpeg")

    def _drop_short_segments(
        self, segments: list[dict], min_duration: float = 0.3
    ) -> list[dict]:
        return [s for s in segments if (s["end"] - s["start"]) >= min_duration]

    def _merge_segments(
        self, segments: list[dict], gap_threshold: float = 0.5
    ) -> list[dict]:
        if not segments:
            return []
        merged = [segments[0].copy()]
        for seg in segments[1:]:
            last = merged[-1]
            gap = seg["start"] - last["end"]
            if seg["speaker"] == last["speaker"] and 0 <= gap <= gap_threshold:
                last["end"] = seg["end"]
            elif gap < 0:
                raise RuntimeError(
                    f"overlapping segments detected (should not happen with exclusive): "
                    f"{last} vs {seg}"
                )
            else:
                merged.append(seg.copy())
        return merged

    def _format_diarized_transcript(self, results: list[dict]) -> str:
        lines = []
        for r in results:
            speaker = r.get("speaker", "UNKNOWN")
            transcript = r.get("transcript", "").strip()
            lines.append(f"{speaker}: {transcript}")
        return "\n".join(lines)


if __name__ == "__main__":
    server = Server()

    def shutdown(signum, frame):
        # Only request shutdown — do not block or exit here.
        # The run loop will exit naturally when _running becomes false.
        server._running = False
        logger.info("Shutdown requested (signal %d)", signum)

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)

    load_time = server.load_model()
    server.start()  # bind socket before emitting ready
    if _ASR_BACKEND == "sensevoice":
        logger.info("Backend: %s model=%s device=%s language=%s output_script=%s",
            server._backend_name, _SENSEVOICE_MODEL, _SENSEVOICE_DEVICE,
            _SENSEVOICE_LANGUAGE, _SENSEVOICE_OUTPUT_SCRIPT)
    elif _ASR_BACKEND == "mlx":
        logger.info("Backend: %s model=%s", server._backend_name, _MLX_MODEL_ID)
    logger.info("Model ready (load time %.2fs), socket listening", load_time)
    print("ready", file=sys.stderr, flush=True)
    server.run()    # blocks until _running goes false
    server.stop()   # clean up socket after run loop exits
