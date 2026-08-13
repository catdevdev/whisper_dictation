#!/usr/bin/env python3
"""Persistent NDJSON sidecar for local Qwen3-TTS synthesis on Apple silicon.

stdout is reserved for protocol messages. All library output and diagnostics are
redirected to stderr before MLX-Audio is imported.
"""

from __future__ import annotations

import base64
import json
import os
import queue
import re
import signal
import sys
import threading
import traceback
from dataclasses import dataclass
from typing import Any


PROTOCOL_VERSION = 1
DEFAULT_MODEL_ID = "mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-bf16"
MLX_AUDIO_VERSION = "0.4.6"
MAX_INPUT_LINE_BYTES = 1_048_576
MAX_TEXT_CHARACTERS = 20_000
MAX_TEXT_BYTES = 100_000
MAX_STYLE_CHARACTERS = 1_000
MAX_AUDIO_SAMPLES_PER_EVENT = 48_000
MAX_QUEUED_OPERATIONS = 4
DEFAULT_STREAMING_INTERVAL = 0.32
MIN_STREAMING_INTERVAL = 0.16
MAX_STREAMING_INTERVAL = 2.0

VOICES = (
    {"id": "Vivian", "displayName": "Vivian", "locale": "zh-CN"},
    {"id": "Serena", "displayName": "Serena", "locale": "zh-CN"},
    {"id": "Uncle_Fu", "displayName": "Uncle Fu", "locale": "zh-CN"},
    {"id": "Dylan", "displayName": "Dylan", "locale": "zh-CN"},
    {"id": "Eric", "displayName": "Eric", "locale": "zh-CN"},
    {"id": "Ryan", "displayName": "Ryan", "locale": "en-US"},
    {"id": "Aiden", "displayName": "Aiden", "locale": "en-US"},
    {"id": "Ono_Anna", "displayName": "Ono Anna", "locale": "ja-JP"},
    {"id": "Sohee", "displayName": "Sohee", "locale": "ko-KR"},
)
VOICE_IDS = {voice["id"] for voice in VOICES}
VOICE_LOOKUP = {voice_id.casefold(): voice_id for voice_id in VOICE_IDS}

LANGUAGES = (
    "Auto",
    "Chinese",
    "English",
    "Japanese",
    "Korean",
    "German",
    "French",
    "Russian",
    "Portuguese",
    "Spanish",
    "Italian",
)
LANGUAGE_LOOKUP = {language.casefold(): language for language in LANGUAGES}

# Constrain downloads to the expected MLX Qwen CustomVoice family. In
# particular, protocol clients cannot pass local paths or arbitrary Hub repos.
MODEL_ID_PATTERN = re.compile(
    r"^mlx-community/Qwen3-TTS-12Hz-(?:0\.6B|1\.7B)-CustomVoice-"
    r"(?:bf16|8bit|6bit|4bit)$"
)
REQUEST_ID_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$")


def _reserve_protocol_stdout() -> Any:
    protocol_fd = os.dup(sys.stdout.fileno())
    protocol_output = os.fdopen(
        protocol_fd,
        "w",
        encoding="utf-8",
        errors="strict",
        buffering=1,
    )
    os.dup2(sys.stderr.fileno(), sys.stdout.fileno())
    sys.stdout = sys.stderr
    return protocol_output


_PROTOCOL_OUTPUT = _reserve_protocol_stdout()
_OUTPUT_LOCK = threading.Lock()
_STATE_LOCK = threading.Lock()
_WORK_QUEUE: queue.Queue[Operation | None]
_WORK_QUEUE = queue.Queue(maxsize=MAX_QUEUED_OPERATIONS)
_CANCELLATIONS: dict[str, threading.Event] = {}
_PENDING_OPERATIONS: dict[str, str] = {}
_SHUTTING_DOWN = threading.Event()
_ACTIVE_ID: str | None = None
_MODEL: Any = None
_MODEL_ID: str | None = None


@dataclass(frozen=True)
class Operation:
    request_id: str
    command: str
    payload: dict[str, Any]
    cancellation: threading.Event


class ProtocolError(Exception):
    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code


def emit(message: dict[str, Any]) -> None:
    encoded = json.dumps(
        message,
        ensure_ascii=False,
        allow_nan=False,
        separators=(",", ":"),
    )
    with _OUTPUT_LOCK:
        _PROTOCOL_OUTPUT.write(encoded)
        _PROTOCOL_OUTPUT.write("\n")
        _PROTOCOL_OUTPUT.flush()


def emit_error(
    request_id: str | None,
    code: str,
    message: str,
    *,
    recoverable: bool,
) -> None:
    safe_message = " ".join(str(message).split())[:1_000]
    payload: dict[str, Any] = {
        "type": "error",
        "code": code,
        "message": safe_message or "Unknown worker error.",
        "recoverable": recoverable,
    }
    if request_id is not None:
        payload["id"] = request_id
    emit(payload)


def emit_status(
    request_id: str | None,
    state: str,
    *,
    detail: str | None = None,
    model_id: str | None = None,
) -> None:
    payload: dict[str, Any] = {"type": "status", "state": state}
    if request_id is not None:
        payload["id"] = request_id
    if detail:
        payload["detail"] = detail[:500]
    if model_id:
        payload["modelID"] = model_id
    emit(payload)


def ready_payload(request_id: str | None = None) -> dict[str, Any]:
    payload: dict[str, Any] = {
        "type": "ready",
        "protocolVersion": PROTOCOL_VERSION,
        "pythonVersion": ".".join(str(part) for part in sys.version_info[:3]),
        "mlxAudioVersion": MLX_AUDIO_VERSION,
        "defaultModelID": DEFAULT_MODEL_ID,
        "modelID": _MODEL_ID,
        "voices": list(VOICES),
        "languages": list(LANGUAGES),
        "capabilities": {
            "streamingPCM": True,
            "cancellation": True,
            "warmup": True,
            "styleInstruction": True,
            "audioFormat": "f32le",
        },
    }
    if request_id is not None:
        payload["id"] = request_id
    return payload


def require_request_id(payload: dict[str, Any]) -> str:
    request_id = payload.get("id")
    if not isinstance(request_id, str) or not REQUEST_ID_PATTERN.fullmatch(request_id):
        raise ProtocolError(
            "invalid_id",
            "id must contain 1-128 ASCII letters, digits, dots, colons, underscores, or hyphens.",
        )
    return request_id


def optional_string(
    payload: dict[str, Any],
    key: str,
    *,
    maximum_characters: int,
    allow_empty: bool = True,
) -> str | None:
    value = payload.get(key)
    if value is None:
        return None
    if not isinstance(value, str):
        raise ProtocolError("invalid_field", f"{key} must be a string.")
    if len(value) > maximum_characters:
        raise ProtocolError(
            "invalid_field",
            f"{key} exceeds the {maximum_characters}-character limit.",
        )
    if not allow_empty and not value.strip():
        raise ProtocolError("invalid_field", f"{key} must not be empty.")
    return value


def normalized_model_id(payload: dict[str, Any]) -> str:
    model_id = payload.get("modelID", DEFAULT_MODEL_ID)
    if not isinstance(model_id, str) or not MODEL_ID_PATTERN.fullmatch(model_id):
        raise ProtocolError(
            "invalid_model",
            "modelID must name an mlx-community Qwen3-TTS CustomVoice model.",
        )
    return model_id


def normalized_voice(payload: dict[str, Any], default: str = "Serena") -> str:
    candidate = payload.get("voice", default)
    if not isinstance(candidate, str):
        raise ProtocolError("invalid_voice", "voice must be a string.")
    voice = VOICE_LOOKUP.get(candidate.casefold())
    if voice is None:
        raise ProtocolError(
            "invalid_voice",
            f"Unsupported voice. Choose one of: {', '.join(sorted(VOICE_IDS))}.",
        )
    return voice


def normalized_language(payload: dict[str, Any], default: str = "Auto") -> str:
    candidate = payload.get("language", default)
    if not isinstance(candidate, str):
        raise ProtocolError("invalid_language", "language must be a string.")
    language = LANGUAGE_LOOKUP.get(candidate.casefold())
    if language is None:
        raise ProtocolError(
            "invalid_language",
            f"Unsupported language. Choose one of: {', '.join(LANGUAGES)}.",
        )
    return language


def normalized_streaming_interval(payload: dict[str, Any]) -> float:
    candidate = payload.get("streamingInterval", DEFAULT_STREAMING_INTERVAL)
    if isinstance(candidate, bool) or not isinstance(candidate, (int, float)):
        raise ProtocolError(
            "invalid_streaming_interval",
            "streamingInterval must be a number.",
        )
    interval = float(candidate)
    if not MIN_STREAMING_INTERVAL <= interval <= MAX_STREAMING_INTERVAL:
        raise ProtocolError(
            "invalid_streaming_interval",
            f"streamingInterval must be between {MIN_STREAMING_INTERVAL} and "
            f"{MAX_STREAMING_INTERVAL} seconds.",
        )
    return interval


def validated_synthesis_payload(payload: dict[str, Any]) -> dict[str, Any]:
    text = optional_string(
        payload,
        "text",
        maximum_characters=MAX_TEXT_CHARACTERS,
        allow_empty=False,
    )
    assert text is not None
    if len(text.encode("utf-8")) > MAX_TEXT_BYTES:
        raise ProtocolError(
            "text_too_large",
            f"text exceeds the {MAX_TEXT_BYTES}-byte UTF-8 limit.",
        )
    style = optional_string(
        payload,
        "style",
        maximum_characters=MAX_STYLE_CHARACTERS,
    )
    return {
        "text": text,
        "voice": normalized_voice(payload),
        "language": normalized_language(payload),
        "style": style.strip() if style and style.strip() else None,
        "streamingInterval": normalized_streaming_interval(payload),
        "modelID": normalized_model_id(payload),
    }


def validated_warmup_payload(payload: dict[str, Any]) -> dict[str, Any]:
    return {
        "text": "Готово.",
        "voice": normalized_voice(payload),
        "language": normalized_language(payload, default="Russian"),
        "style": None,
        "streamingInterval": DEFAULT_STREAMING_INTERVAL,
        "modelID": normalized_model_id(payload),
    }


def ensure_model(
    request_id: str,
    model_id: str,
    cancellation: threading.Event,
) -> Any:
    global _MODEL
    global _MODEL_ID

    if _MODEL is not None and _MODEL_ID == model_id:
        return _MODEL
    if cancellation.is_set() or _SHUTTING_DOWN.is_set():
        raise InterruptedError

    emit_status(request_id, "loading_model", model_id=model_id)
    try:
        from importlib.metadata import version

        installed_version = version("mlx-audio")
        if installed_version != MLX_AUDIO_VERSION:
            raise RuntimeError(
                f"mlx-audio {MLX_AUDIO_VERSION} is required; found {installed_version}."
            )

        from mlx_audio.tts.utils import load_model

        model = load_model(model_id)
    except Exception:
        traceback.print_exc(file=sys.stderr)
        raise

    if cancellation.is_set() or _SHUTTING_DOWN.is_set():
        del model
        raise InterruptedError

    _MODEL = model
    _MODEL_ID = model_id
    emit_status(request_id, "model_loaded", model_id=model_id)
    return model


def audio_as_little_endian_float32(audio: Any) -> Any:
    import numpy as np

    samples = np.asarray(audio, dtype=np.float32).reshape(-1)
    samples = np.nan_to_num(samples, nan=0.0, posinf=1.0, neginf=-1.0)
    samples = np.clip(samples, -1.0, 1.0)
    return np.ascontiguousarray(samples, dtype="<f4")


def generate_audio(
    operation: Operation,
    values: dict[str, Any],
    *,
    discard_audio: bool,
) -> tuple[int, int, int]:
    model = ensure_model(
        operation.request_id,
        values["modelID"],
        operation.cancellation,
    )
    if operation.cancellation.is_set() or _SHUTTING_DOWN.is_set():
        raise InterruptedError

    generator = model.generate_custom_voice(
        text=values["text"],
        speaker=values["voice"],
        language=values["language"],
        instruct=values["style"],
        verbose=False,
        stream=True,
        streaming_interval=values["streamingInterval"],
    )

    sequence = 0
    total_samples = 0
    sample_rate = int(getattr(model, "sample_rate", 24_000))
    for result in generator:
        if operation.cancellation.is_set() or _SHUTTING_DOWN.is_set():
            close = getattr(generator, "close", None)
            if callable(close):
                close()
            raise InterruptedError

        sample_rate = int(getattr(result, "sample_rate", sample_rate))
        samples = audio_as_little_endian_float32(result.audio)
        total_samples += int(samples.size)
        if discard_audio:
            continue

        for offset in range(0, int(samples.size), MAX_AUDIO_SAMPLES_PER_EVENT):
            if operation.cancellation.is_set() or _SHUTTING_DOWN.is_set():
                close = getattr(generator, "close", None)
                if callable(close):
                    close()
                raise InterruptedError
            chunk = samples[offset : offset + MAX_AUDIO_SAMPLES_PER_EVENT]
            emit(
                {
                    "type": "audio",
                    "id": operation.request_id,
                    "sequence": sequence,
                    "sampleRate": sample_rate,
                    "channels": 1,
                    "format": "f32le",
                    "data": base64.b64encode(chunk.tobytes(order="C")).decode("ascii"),
                    "isFinal": False,
                }
            )
            sequence += 1

    return sample_rate, sequence, total_samples


def execute_operation(operation: Operation) -> None:
    global _ACTIVE_ID

    with _STATE_LOCK:
        _ACTIVE_ID = operation.request_id

    try:
        if operation.cancellation.is_set() or _SHUTTING_DOWN.is_set():
            raise InterruptedError

        if operation.command == "load":
            model_id = normalized_model_id(operation.payload)
            ensure_model(operation.request_id, model_id, operation.cancellation)
            emit(
                {
                    "type": "completed",
                    "id": operation.request_id,
                    "operation": "load",
                    "modelID": model_id,
                    "cancelled": False,
                }
            )
            return

        if operation.command == "warmup":
            values = validated_warmup_payload(operation.payload)
            emit_status(operation.request_id, "warming_up", model_id=values["modelID"])
            sample_rate, _, total_samples = generate_audio(
                operation,
                values,
                discard_audio=True,
            )
            emit(
                {
                    "type": "completed",
                    "id": operation.request_id,
                    "operation": "warmup",
                    "modelID": values["modelID"],
                    "sampleRate": sample_rate,
                    "chunks": 0,
                    "samples": total_samples,
                    "cancelled": False,
                }
            )
            return

        if operation.command == "synthesize":
            values = validated_synthesis_payload(operation.payload)
            emit_status(
                operation.request_id,
                "generating",
                model_id=values["modelID"],
            )
            sample_rate, chunks, total_samples = generate_audio(
                operation,
                values,
                discard_audio=False,
            )
            emit(
                {
                    "type": "completed",
                    "id": operation.request_id,
                    "operation": "synthesize",
                    "modelID": values["modelID"],
                    "sampleRate": sample_rate,
                    "chunks": chunks,
                    "samples": total_samples,
                    "cancelled": False,
                }
            )
            return

        raise ProtocolError("invalid_command", "Unsupported queued operation.")
    except InterruptedError:
        emit(
            {
                "type": "cancelled",
                "id": operation.request_id,
                "operation": operation.command,
            }
        )
    except ProtocolError as error:
        emit_error(
            operation.request_id,
            error.code,
            str(error),
            recoverable=True,
        )
    except Exception as error:
        traceback.print_exc(file=sys.stderr)
        code = (
            "model_load_failed"
            if operation.command == "load" or _MODEL is None
            else "generation_failed"
        )
        emit_error(
            operation.request_id,
            code,
            str(error) or type(error).__name__,
            recoverable=True,
        )
    finally:
        with _STATE_LOCK:
            _ACTIVE_ID = None
            _PENDING_OPERATIONS.pop(operation.request_id, None)
            _CANCELLATIONS.pop(operation.request_id, None)


def work_loop() -> None:
    while not _SHUTTING_DOWN.is_set():
        operation = _WORK_QUEUE.get()
        if operation is None:
            return
        execute_operation(operation)


def enqueue_operation(payload: dict[str, Any], command: str) -> None:
    request_id = require_request_id(payload)

    if command == "load":
        normalized_model_id(payload)
    elif command == "warmup":
        validated_warmup_payload(payload)
    elif command == "synthesize":
        validated_synthesis_payload(payload)

    with _STATE_LOCK:
        if request_id in _PENDING_OPERATIONS:
            raise ProtocolError("duplicate_id", "A request with this id is already pending.")
        cancellation = threading.Event()
        operation = Operation(request_id, command, payload, cancellation)
        try:
            _WORK_QUEUE.put_nowait(operation)
        except queue.Full as error:
            raise ProtocolError(
                "busy",
                "The worker already has too many queued operations.",
            ) from error
        _PENDING_OPERATIONS[request_id] = command
        _CANCELLATIONS[request_id] = cancellation

    emit_status(request_id, "queued", model_id=payload.get("modelID"))


def cancel_operation(payload: dict[str, Any]) -> None:
    request_id = require_request_id(payload)
    target_id = payload.get("targetID")
    if not isinstance(target_id, str) or not REQUEST_ID_PATTERN.fullmatch(target_id):
        raise ProtocolError("invalid_id", "targetID is missing or invalid.")

    with _STATE_LOCK:
        cancellation = _CANCELLATIONS.get(target_id)
    if cancellation is None:
        emit_error(
            request_id,
            "request_not_found",
            "No pending operation has the requested targetID.",
            recoverable=True,
        )
        return

    cancellation.set()
    emit_status(request_id, "cancellation_requested", detail=target_id)


def report_status(payload: dict[str, Any]) -> None:
    request_id = require_request_id(payload)
    with _STATE_LOCK:
        active_id = _ACTIVE_ID
        pending_count = len(_PENDING_OPERATIONS)
        model_id = _MODEL_ID
    emit(
        {
            "type": "status",
            "id": request_id,
            "state": "busy" if pending_count else "idle",
            "activeID": active_id,
            "pendingCount": pending_count,
            "modelID": model_id,
        }
    )


def dispatch(payload: Any) -> bool:
    if not isinstance(payload, dict):
        raise ProtocolError("invalid_request", "Each request must be a JSON object.")
    command = payload.get("command")
    if not isinstance(command, str):
        raise ProtocolError("invalid_command", "command must be a string.")

    if command in {"load", "warmup", "synthesize"}:
        enqueue_operation(payload, command)
    elif command == "cancel":
        cancel_operation(payload)
    elif command == "status":
        report_status(payload)
    elif command == "hello":
        emit(ready_payload(require_request_id(payload)))
    elif command == "catalog":
        request_id = require_request_id(payload)
        emit(
            {
                "type": "catalog",
                "id": request_id,
                "defaultModelID": DEFAULT_MODEL_ID,
                "voices": list(VOICES),
                "languages": list(LANGUAGES),
            }
        )
    elif command == "shutdown":
        request_id = require_request_id(payload)
        _SHUTTING_DOWN.set()
        with _STATE_LOCK:
            cancellations = list(_CANCELLATIONS.values())
        for cancellation in cancellations:
            cancellation.set()
        emit(
            {
                "type": "completed",
                "id": request_id,
                "operation": "shutdown",
                "cancelled": False,
            }
        )
        return False
    else:
        raise ProtocolError("invalid_command", f"Unsupported command: {command[:100]}")
    return True


def drain_oversized_line() -> None:
    while True:
        remainder = sys.stdin.buffer.readline(MAX_INPUT_LINE_BYTES + 1)
        if not remainder or remainder.endswith(b"\n"):
            return


def request_shutdown(_signum: int, _frame: Any) -> None:
    _SHUTTING_DOWN.set()
    raise SystemExit(0)


def main() -> int:
    signal.signal(signal.SIGTERM, request_shutdown)
    signal.signal(signal.SIGINT, request_shutdown)

    worker_thread = threading.Thread(
        target=work_loop,
        name="qwen-mlx-worker",
        daemon=True,
    )
    worker_thread.start()
    emit(ready_payload())

    while not _SHUTTING_DOWN.is_set():
        line = sys.stdin.buffer.readline(MAX_INPUT_LINE_BYTES + 1)
        if not line:
            _SHUTTING_DOWN.set()
            break
        if len(line) > MAX_INPUT_LINE_BYTES:
            if not line.endswith(b"\n"):
                drain_oversized_line()
            emit_error(
                None,
                "request_too_large",
                f"NDJSON requests are limited to {MAX_INPUT_LINE_BYTES} bytes.",
                recoverable=True,
            )
            continue
        if not line.strip():
            continue

        request_id: str | None = None
        try:
            payload = json.loads(line.decode("utf-8"))
            if isinstance(payload, dict) and isinstance(payload.get("id"), str):
                request_id = payload["id"][:128]
            if not dispatch(payload):
                break
        except UnicodeDecodeError:
            emit_error(
                None,
                "invalid_encoding",
                "Requests must be UTF-8 encoded.",
                recoverable=True,
            )
        except json.JSONDecodeError:
            emit_error(
                None,
                "invalid_json",
                "Each input line must contain one valid JSON object.",
                recoverable=True,
            )
        except ProtocolError as error:
            emit_error(request_id, error.code, str(error), recoverable=True)
        except Exception as error:
            traceback.print_exc(file=sys.stderr)
            emit_error(
                request_id,
                "internal_error",
                str(error) or type(error).__name__,
                recoverable=False,
            )

    try:
        _WORK_QUEUE.put_nowait(None)
    except queue.Full:
        pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
