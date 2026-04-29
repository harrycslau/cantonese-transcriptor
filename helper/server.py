#!/usr/bin/env python3
"""Persistent ASR helper server — Unix socket, NDJSON, JSON-RPC 2.0."""

import json
import logging
import os
import signal
import socket
import sys
import uuid
from pathlib import Path

# Ensure helper dir is on path for imports
sys.path.insert(0, str(Path(__file__).parent))

from model import TranscriptionModel
import protocol


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
        self._model = TranscriptionModel()
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

        try:
            self._in_progress = True
            duration = self._model._get_audio_duration(audio_path)
            if duration > 0 and duration <= 90:
                transcript, transcribe_time, audio_duration = self._model.transcribe(audio_path)
            else:
                def progress_callback(jid, chunk, total, stage):
                    notify = protocol.build_progress_notification(jid, chunk, total, stage)
                    conn.sendall((json.dumps(notify) + "\n").encode("utf-8"))
                transcript, transcribe_time, audio_duration = self._model.transcribe_chunked(
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
            resp = protocol.build_error_response(-32603, str(e), job_id, data.get("id"))
            conn.sendall((json.dumps(resp) + "\n").encode("utf-8"))
        finally:
            self._in_progress = False


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
    print("ready", file=sys.stderr, flush=True)
    logger.info("Model ready (load time %.2fs), socket listening", load_time)
    server.run()    # blocks until _running goes false
    server.stop()   # clean up socket after run loop exits
