"""API shim for local inference services.

This service keeps native app calls simple by exposing a thin contract on one
localhost port:
- `/v1/audio/speech` proxies to MiniMax-Music3 (via sglang-omni).
- `/transcribe/midi` proxies to MuScriptor.

The service can optionally write MIDI output to local storage and return a
download path for your app to persist/caching logic around.
"""

from __future__ import annotations

import asyncio
import logging
import os
import uuid
from pathlib import Path
from typing import Any

import httpx
from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, Response

logging.basicConfig(level=logging.INFO)
log = logging.getLogger("micromix-api")


app = FastAPI(title="micromix-api", version="0.1.0")

_cors_origins = os.getenv("CORS_ORIGINS", "*")
if _cors_origins == "*":
    allow_origins = ["*"]
else:
    allow_origins = [x.strip() for x in _cors_origins.split(",") if x.strip()]

app.add_middleware(
    CORSMiddleware,
    allow_origins=allow_origins,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

MINIMAX_UPSTREAM_URL = os.getenv("MINIMAX_UPSTREAM_URL", "http://minimax-music3:8900")
MUSCRIPTOR_UPSTREAM_URL = os.getenv("MUSCRIPTOR_UPSTREAM_URL", "http://muscriptor:8901")
MINIMAX_DEFAULT_MODEL = os.getenv("MINIMAX_MODEL", "MiniMaxAI/MiniMax-Music3")

MINIMAX_TIMEOUT_SECONDS = float(os.getenv("MINIMAX_API_TIMEOUT_SECONDS", "1200"))
MUSCRIPTOR_TIMEOUT_SECONDS = float(os.getenv("MUSCRIPTOR_API_TIMEOUT_SECONDS", "1200"))
MAX_REQUEST_SIZE_MB = int(os.getenv("MAX_REQUEST_SIZE_MB", "200"))
MAX_REQUEST_SIZE_BYTES = MAX_REQUEST_SIZE_MB * 1024 * 1024
OUTPUT_DIR = Path(os.getenv("OUTPUT_DIR", "/data"))
MIDI_OUTPUT_DIR = (OUTPUT_DIR / "midi").resolve()
MIDI_OUTPUT_DIR.mkdir(parents=True, exist_ok=True)


def _normalize_instruments(instruments: list[str] | None) -> list[str]:
    if not instruments:
        return []
    normalized: list[str] = []
    for value in instruments:
        if not value:
            continue
        if "," in value:
            normalized.extend([item.strip() for item in value.split(",") if item.strip()])
        else:
            value = value.strip()
            if value:
                normalized.append(value)
    return normalized


def _sanitize_content_type(raw: str | None) -> str:
    if not raw:
        return "application/octet-stream"
    return raw.split(";", 1)[0].strip() or "application/octet-stream"


async def _forward_request(
    *,
    method: str,
    url: str,
    json_payload: dict[str, Any] | None = None,
    files: dict[str, tuple[str, bytes, str]] | None = None,
    data: list[tuple[str, str]] | None = None,
    timeout_seconds: float = 1200.0,
) -> httpx.Response:
    timeout = httpx.Timeout(timeout=timeout_seconds, connect=60.0, read=timeout_seconds)
    async with httpx.AsyncClient(timeout=timeout) as client:
        if method == "get":
            return await client.get(url)
        if method == "json":
            return await client.post(url, json=json_payload)
        if method == "form":
            return await client.post(url, data=data, files=files)
        raise ValueError(f"unsupported method for _forward_request: {method}")


async def _check_service(url: str, path: str, timeout_seconds: float) -> str:
    try:
        resp = await _forward_request(
            method="get", url=f"{url}{path}", timeout_seconds=timeout_seconds
        )
        return "ok" if resp.status_code == 200 else "error"
    except Exception as exc:
        log.warning("upstream %s check failed: %s", url, exc)
        return "unreachable"


@app.get("/health")
async def health() -> dict[str, str]:
    minimax_status, muscriptor_status = await asyncio.gather(
        _check_service(MINIMAX_UPSTREAM_URL, "/health", MINIMAX_TIMEOUT_SECONDS),
        _check_service(MUSCRIPTOR_UPSTREAM_URL, "/health", MUSCRIPTOR_TIMEOUT_SECONDS),
    )
    return {
        "service": "micromix-api",
        "status": "ok",
        "minimax": minimax_status,
        "muscriptor": muscriptor_status,
    }


@app.post("/v1/audio/speech")
async def minimax_audio_speech(payload: dict[str, Any]):
    request_payload = dict(payload)
    input_text = request_payload.get("input")
    if not input_text and request_payload.get("lyrics"):
        input_text = request_payload.pop("lyrics")
        request_payload["input"] = input_text

    if not isinstance(input_text, str) or not input_text.strip():
        raise HTTPException(
            status_code=400,
            detail="`input` (lyrics/text prompt) is required for minimax generation.",
        )

    request_payload.setdefault("model", MINIMAX_DEFAULT_MODEL)
    request_payload.setdefault("response_format", "wav")
    if request_payload.get("stream") is True:
        raise HTTPException(
            status_code=400,
            detail="Streaming is not supported by this shim. Use stream=false or omit it.",
        )

    upstream_url = f"{MINIMAX_UPSTREAM_URL}/v1/audio/speech"
    try:
        resp = await _forward_request(
            method="json",
            url=upstream_url,
            json_payload=request_payload,
            timeout_seconds=MINIMAX_TIMEOUT_SECONDS,
        )
    except httpx.TimeoutException as exc:
        raise HTTPException(status_code=408, detail="minimax request timed out") from exc
    except Exception as exc:  # noqa: BLE001
        raise HTTPException(status_code=503, detail=f"failed to call minimax: {exc}") from exc

    if resp.status_code >= 400:
        raise HTTPException(
            status_code=resp.status_code,
            detail=resp.text[:2000] or "minimax returned an error",
        )

    return Response(
        content=resp.content,
        media_type=_sanitize_content_type(resp.headers.get("content-type")),
        headers={"Content-Disposition": 'attachment; filename="result.wav"'},
    )


@app.post("/transcribe/midi")
async def transcribe_midi(
    audio_file: UploadFile = File(...),
    instruments: list[str] = Form(default_factory=list),
    detect_tempo: str = Form("best-effort"),
    return_file: bool = Form(False),
) -> Response | dict[str, Any]:
    file_bytes = await audio_file.read()
    if not file_bytes:
        raise HTTPException(status_code=400, detail="no file provided")
    if len(file_bytes) > MAX_REQUEST_SIZE_BYTES:
        raise HTTPException(
            status_code=413,
            detail=(
                f"audio upload too large ({len(file_bytes)/1024/1024:.1f} MiB). "
                f"Maximum is {MAX_REQUEST_SIZE_MB} MiB."
            ),
        )
    normalized_instruments = _normalize_instruments(instruments)

    fields: list[tuple[str, str]] = [("detect_tempo", detect_tempo)]
    fields.extend(("instruments", name) for name in normalized_instruments)
    files = {
        "file": (
            audio_file.filename or "input.wav",
            file_bytes,
            audio_file.content_type or "application/octet-stream",
        )
    }

    upstream_url = f"{MUSCRIPTOR_UPSTREAM_URL}/transcribe/midi"
    try:
        resp = await _forward_request(
            method="form",
            url=upstream_url,
            files=files,
            data=fields,
            timeout_seconds=MUSCRIPTOR_TIMEOUT_SECONDS,
        )
    except httpx.TimeoutException as exc:
        raise HTTPException(status_code=408, detail="muscriptor request timed out") from exc
    except Exception as exc:  # noqa: BLE001
        raise HTTPException(status_code=503, detail=f"failed to call muscriptor: {exc}") from exc

    if resp.status_code >= 400:
        raise HTTPException(
            status_code=resp.status_code,
            detail=resp.text[:2000] or "muscriptor returned an error",
        )

    if not return_file:
        return Response(
            content=resp.content,
            media_type=_sanitize_content_type(resp.headers.get("content-type")),
            headers={"Content-Disposition": 'attachment; filename="result.mid"'},
        )

    output_file = MIDI_OUTPUT_DIR / f"{uuid.uuid4().hex}.mid"
    output_file.write_bytes(resp.content)
    return {
        "status": "ok",
        "path": f"/files/{output_file.name}",
        "filename": output_file.name,
        "size_bytes": len(resp.content),
    }


@app.get("/files/{filename}")
async def get_file(filename: str) -> FileResponse:
    path = MIDI_OUTPUT_DIR / filename
    if not path.exists() or not path.is_file():
        raise HTTPException(status_code=404, detail="file not found")
    return FileResponse(
        path=path,
        filename=path.name,
        media_type="audio/midi",
    )


@app.get("/instruments")
async def list_instruments() -> dict[str, list[str]]:
    upstream_url = f"{MUSCRIPTOR_UPSTREAM_URL}/instruments"
    try:
        resp = await _forward_request(
            method="get", url=upstream_url, timeout_seconds=10
        )
    except Exception as exc:  # noqa: BLE001
        raise HTTPException(status_code=503, detail=f"failed to query muscriptor: {exc}") from exc
    if resp.status_code >= 400:
        raise HTTPException(status_code=resp.status_code, detail=resp.text[:2000])
    return resp.json()
