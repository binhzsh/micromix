from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field


ASSET_ROOT = Path(os.getenv("ASSET_ROOT", "/data")).resolve()
VOICE_ROOT = Path(os.getenv("VOICE_ROOT", "/voices")).resolve()
RVC_ROOT = Path(os.getenv("RVC_ROOT", "/opt/rvc")).resolve()
RVC_CLI = RVC_ROOT / "infer" / "cli.py"

app = FastAPI(title="micromix-rvc-worker", version="0.1.0")


class ConversionRequest(BaseModel):
    source_path: str
    model_path: str
    index_path: str | None = None
    output_path: str
    pitch_shift_semitones: int = Field(ge=-24, le=24)
    f0_method: str = "rmvpe"


def contained(path: str, root: Path, label: str) -> Path:
    value = Path(path).resolve()
    if not value.is_relative_to(root):
        raise HTTPException(status_code=422, detail=f"{label} must remain within its mounted root")
    return value


@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ready" if RVC_CLI.is_file() else "cold"}


@app.post("/convert")
def convert(request: ConversionRequest) -> dict[str, str]:
    if request.f0_method != "rmvpe":
        raise HTTPException(status_code=422, detail="unsupported vocal pitch method")
    source = contained(request.source_path, ASSET_ROOT, "source path")
    model = contained(request.model_path, VOICE_ROOT, "model path")
    output = contained(request.output_path, ASSET_ROOT, "output path")
    index = contained(request.index_path, VOICE_ROOT, "index path") if request.index_path else None
    if not source.is_file() or not model.is_file() or (index is not None and not index.is_file()):
        raise HTTPException(status_code=422, detail="source or private voice profile is unavailable")
    if output.suffix.lower() != ".wav":
        raise HTTPException(status_code=422, detail="vocal conversion output must be WAV")
    if not RVC_CLI.is_file():
        raise HTTPException(status_code=503, detail="private voice conversion runtime is unavailable")
    output.parent.mkdir(parents=True, exist_ok=True)
    command = [
        sys.executable,
        str(RVC_CLI),
        "--model", str(model),
        "--input", str(source),
        "--output", str(output),
        "--pitch", str(request.pitch_shift_semitones),
        "--f0-method", request.f0_method,
        "--index-rate", "0.75",
        "--overwrite",
    ]
    if index is not None:
        command.extend(["--index", str(index)])
    try:
        subprocess.run(command, cwd=RVC_ROOT, check=True, capture_output=True, text=True)
    except subprocess.CalledProcessError as exc:
        detail = (exc.stderr or exc.stdout or "private voice conversion failed").strip()
        raise HTTPException(status_code=502, detail=detail[-1000:]) from exc
    if not output.is_file() or output.stat().st_size == 0:
        raise HTTPException(status_code=502, detail="private voice conversion produced no audio")
    return {"output_path": str(output)}
