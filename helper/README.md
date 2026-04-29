# ASR Helper — Milestone 1 & 2

## Milestone 1: One-shot CLI

```bash
pip install -r requirements.txt
python transcribe.py <path_to_audio.wav>
# Example:
python transcribe.py ../audio/cantonese_test.wav
```

## Milestone 2: Persistent Server

### Start

```bash
python server.py &
# Wait for stderr: ready
# Model loads, server binds to /tmp/cantonese-transcriptor.sock
```

### Send a request

```python
import socket, json

sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.connect("/tmp/cantonese-transcriptor.sock")

request = {
    "jsonrpc": "2.0",
    "method": "transcribe",
    "params": {
        "audio_path": "/absolute/path/to/audio.wav",
        "job_id": "uuid-string"
    },
    "id": 1
}
sock.sendall((json.dumps(request) + "\n").encode())
response = sock.recv(8192).decode()
sock.close()
```

### Request schema

```json
{
  "jsonrpc": "2.0",
  "method": "transcribe",
  "params": {
    "audio_path": "/absolute/path/to/audio.wav",
    "job_id": "uuid-string"
  },
  "id": 1
}
```

### Success response schema

```json
{
  "jsonrpc": "2.0",
  "result": {
    "job_id": "uuid-string",
    "transcript": "講緊廣東話四音一二三，testing一二三。",
    "timing": {
      "model_load_time_s": 2.62,
      "transcribe_time_s": 16.72,
      "audio_duration_s": 7.061,
      "real_time_factor": 2.37
    }
  },
  "id": 1
}
```

### Error response schema

```json
{
  "jsonrpc": "2.0",
  "error": {
    "code": -32602,
    "message": "Audio file not found: /path/to/audio.wav",
    "data": { "job_id": "uuid-string" }
  },
  "id": 1
}
```

Error codes:
- `-32600` Invalid request
- `-32601` Method not found
- `-32602` Invalid params
- `-32603` Internal error

### Stop

```bash
kill <pid>  # SIGTERM / SIGINT for graceful shutdown
```

### Offline test

```bash
HF_HUB_OFFLINE=1 python server.py &
```

### Notes

- Socket: `/tmp/cantonese-transcriptor.sock` (persistent connections, NDJSON framing)
- Logs: `/tmp/cantonese-transcriptor.log`
- Stdout is unused — all protocol traffic goes over the socket.
- `model_load_time_s` is returned in every response; it is the startup load time, not per-job.
- The macOS app accepts WAV, MP3, and M4A. Decoding depends on the helper/MLX audio stack.
- Duration timing is accurate for WAV; MP3 and M4A may return 0.0 if duration cannot be determined.