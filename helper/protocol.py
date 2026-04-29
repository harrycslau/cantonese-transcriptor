"""JSON-RPC protocol definitions for the ASR helper."""

import os
from typing import Any


def build_success_response(job_id: str, transcript: str, timing: dict[str, float], rid: int | str) -> dict[str, Any]:
    """Build a JSON-RPC success response."""
    return {
        "jsonrpc": "2.0",
        "result": {
            "job_id": job_id,
            "transcript": transcript,
            "timing": timing,
        },
        "id": rid,
    }


def build_error_response(code: int, message: str, job_id: str | None, rid: int | str) -> dict[str, Any]:
    """Build a JSON-RPC error response."""
    err = {
        "code": code,
        "message": message,
    }
    if job_id is not None:
        err["data"] = {"job_id": job_id}
    return {
        "jsonrpc": "2.0",
        "error": err,
        "id": rid,
    }


def validate_audio_path(audio_path: str) -> tuple[bool, str]:
    """Validate that audio_path is a readable file."""
    if not os.path.exists(audio_path):
        return False, f"Audio file not found: {audio_path}"
    if not os.path.isfile(audio_path):
        return False, f"Not a file: {audio_path}"
    if not os.access(audio_path, os.R_OK):
        return False, f"File not readable: {audio_path}"
    return True, ""