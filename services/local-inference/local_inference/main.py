"""MicroMix local inference sidecar — FastAPI app for Apple Silicon MLX models."""
from __future__ import annotations

import asyncio
import secrets
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Literal

from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from fastapi.responses import FileResponse
from pydantic import BaseModel, Field

# ---------------------------------------------------------------- config

DATA_ROOT = Path(__file__).resolve().parent.parent / "data"
ASSET_ROOT = DATA_ROOT / "assets"
ASSET_ROOT.mkdir(parents=True, exist_ok=True)

SEED_SPACE = 2**32


def _now() -> datetime:
    return datetime.now(timezone.utc)


def _new_job_id() -> str:
    return uuid.uuid4().hex


def _new_asset_id() -> str:
    return uuid.uuid4().hex


# ---------------------------------------------------------------- schemas

class JobState:
    QUEUED = "queued"
    RUNNING = "running"
    SUCCEEDED = "succeeded"
    FAILED = "failed"


class AssetRecord(BaseModel):
    id: str
    filename: str
    media_type: str
    size_bytes: int
    sha256: str
    download_url: str


class JobAssetLink(BaseModel):
    name: str
    position: int
    asset: AssetRecord


class JobRecord(BaseModel):
    id: str
    kind: str
    state: str
    parameters: dict[str, Any]
    progress: float | None = None
    progress_detail: str | None = None
    error: str | None = None
    created_at: datetime
    updated_at: datetime
    inputs: list[JobAssetLink] = Field(default_factory=list)
    outputs: list[JobAssetLink] = Field(default_factory=list)
    asset: AssetRecord | None = None


class GenerationRequest(BaseModel):
    prompt: str = Field(min_length=1, max_length=4000)
    lyrics: str | None = Field(default=None, max_length=50_000)
    preset: Literal["turbo", "quality"] = "turbo"
    seed: int | None = Field(default=None, ge=0, le=4_294_967_295)
    variation_count: int = Field(default=1, ge=1, le=4)
    duration_seconds: float = Field(default=30, ge=10, le=600)
    bpm: int | None = Field(default=None, ge=30, le=300)
    key: str | None = Field(default=None, max_length=32)
    time_signature: Literal["2", "3", "4", "6"] | None = None
    vocal_language: Literal["en", "vi"] | None = None


class VocalSwapRequest(BaseModel):
    source_asset_id: str = Field(min_length=1)
    voice_model: str = Field(min_length=1)
    pitch_shift: int = 0
    index_rate: float = Field(default=0.5, ge=0.0, le=1.0)


class StemSplitRequest(BaseModel):
    source_asset_id: str = Field(min_length=1)
    description: str = Field(min_length=1)


class ReferenceGenerationRequest(BaseModel):
    """Reimagine: generate a new song informed by a reference track.

    The MLX MiniMax port has no audio-conditioning input, so the reference
    contributes its lyrics (extracted via STT when not supplied) and the
    generation follows the user's style prompt.
    """

    prompt: str = Field(min_length=1, max_length=4000)
    lyrics: str | None = Field(default=None, max_length=50_000)
    preset: Literal["turbo", "quality"] = "turbo"
    seed: int | None = Field(default=None, ge=0, le=4_294_967_295)
    variation_count: int = Field(default=1, ge=1, le=4)
    duration_seconds: float = Field(default=30, ge=10, le=600)
    reference_asset_id: str = Field(min_length=1)
    # Accepted for API compatibility; the local model exposes no such controls.
    bpm: int | None = Field(default=None, ge=30, le=300)
    key: str | None = Field(default=None, max_length=32)
    time_signature: Literal["2", "3", "4", "6"] | None = None
    vocal_language: Literal["en", "vi"] | None = None


class RemixRequest(BaseModel):
    """Reimagine: cover-style re-generation from a source track.

    Lyrics come from the request or are extracted from the source via STT;
    the new arrangement follows the style prompt.
    """

    prompt: str = Field(min_length=1, max_length=4000)
    lyrics: str | None = Field(default=None, max_length=50_000)
    preset: Literal["turbo", "quality"] = "turbo"
    seed: int | None = Field(default=None, ge=0, le=4_294_967_295)
    variation_count: int = Field(default=1, ge=1, le=4)
    source_strength: float = Field(default=0.5, ge=0.0, le=1.0)
    source_asset_id: str = Field(min_length=1)


class RepaintRequest(BaseModel):
    """Reimagine: replace a time range of the source with generated audio.

    The replacement segment is generated from the prompt and spliced into
    the original waveform with short crossfades; the rest is preserved.
    """

    prompt: str = Field(min_length=1, max_length=4000)
    lyrics: str | None = Field(default=None, max_length=50_000)
    preset: Literal["turbo", "quality"] = "turbo"
    seed: int | None = Field(default=None, ge=0, le=4_294_967_295)
    variation_count: int = Field(default=1, ge=1, le=4)
    start_seconds: float = Field(ge=0)
    end_seconds: float = Field(gt=0)
    repaint_strength: float = Field(default=0.5, ge=0.0, le=1.0)
    source_asset_id: str = Field(min_length=1)


# ---------------------------------------------------------------- in-memory store

_jobs: dict[str, dict[str, Any]] = {}
_assets: dict[str, dict[str, Any]] = {}

# ---------------------------------------------------------------- model manager

_model_status: dict[str, str] = {
    "minimax_music3": "unloaded",
    "mlx_rvc": "unloaded",
    "sam_audio": "unloaded",
    "basic_pitch": "unloaded",
    "whisper_stt": "unloaded",
}


# ---------------------------------------------------------------- app

app = FastAPI(title="MicroMix Local Inference", version="0.1.0")


@app.get("/v1/health")
def health() -> dict:
    return {
        "service": "micromix-local-inference",
        "status": "ready",
        "models": dict(_model_status),
    }


@app.get("/v1/capabilities")
def capabilities() -> dict:
    return {
        "generation_presets": [
            {
                "id": "minimax-cover",
                "label": "MiniMax Music 3 (Cover)",
                "model": "MiniMax-Music3-mxfp8",
                "inference_steps": 30,
            }
        ],
        "transcription_instruments": ["all"],
        "vocal_models": sorted(_list_voice_models()),
        "stem_targets": ["vocals", "drums", "bass", "other"],
        # Reimagine operations are local approximations: reference/remix use
        # STT-extracted lyrics plus the prompt; repaint splices a generated
        # segment into the source waveform.
        "reimagine_modes": ["reference-generation", "remix", "repaint"],
    }


def _list_voice_models() -> list[str]:
    voice_dir = DATA_ROOT / "voice-models"
    if not voice_dir.is_dir():
        return []
    names = {p.stem for p in voice_dir.glob("*.pth")}
    names |= {p.stem for p in voice_dir.glob("*.safetensors")}
    return sorted(names)


# ---------------------------------------------------------------- asset helpers

def _store_asset(data: bytes, filename: str, media_type: str) -> AssetRecord:
    import hashlib

    asset_id = _new_asset_id()
    path = ASSET_ROOT / f"{asset_id}_{filename}"
    path.write_bytes(data)
    record = AssetRecord(
        id=asset_id,
        filename=filename,
        media_type=media_type,
        size_bytes=len(data),
        sha256=hashlib.sha256(data).hexdigest(),
        download_url=f"/v1/assets/{asset_id}",
    )
    _assets[asset_id] = {"record": record, "path": path}
    return record


def _get_asset_path(asset_id: str) -> Path:
    entry = _assets.get(asset_id)
    if entry is None:
        raise HTTPException(404, f"asset {asset_id} not found")
    return entry["path"]


@app.post("/v1/assets")
async def upload_asset(audio_file: UploadFile = File(...)) -> dict:
    data = await audio_file.read()
    record = _store_asset(data, audio_file.filename or "upload.wav", "audio/wav")
    return record.model_dump()


@app.get("/v1/assets/{asset_id}")
def download_asset(asset_id: str) -> FileResponse:
    path = _get_asset_path(asset_id)
    return FileResponse(path)


# ---------------------------------------------------------------- job runner

import concurrent.futures

_executor = concurrent.futures.ThreadPoolExecutor(max_workers=1)
_pending: set[str] = set()


def _enqueue_job(job_id: str, fn) -> None:
    """Queue work for a job, updating state through the lifecycle."""
    record = _jobs[job_id]
    record["state"] = JobState.RUNNING
    record["updated_at"] = _now()

    def _run() -> None:
        try:
            fn(job_id)
            if _jobs[job_id]["state"] == JobState.RUNNING:
                _jobs[job_id]["state"] = JobState.SUCCEEDED
        except Exception as exc:  # noqa: BLE001 - job errors become job state
            _jobs[job_id]["state"] = JobState.FAILED
            _jobs[job_id]["error"] = str(exc)
        finally:
            _jobs[job_id]["updated_at"] = _now()
            _pending.discard(job_id)

    _pending.add(job_id)
    _executor.submit(_run)


def _job_response(job_id: str) -> dict:
    record = _jobs[job_id]
    outputs = record.get("outputs") or []
    asset = outputs[0]["asset"] if outputs else None
    return {
        "id": record["id"],
        "kind": record["kind"],
        "state": record["state"],
        "parameters": record.get("parameters", {}),
        "progress": record.get("progress"),
        "progress_detail": record.get("progress_detail"),
        "error": record.get("error"),
        "created_at": record["created_at"].isoformat(),
        "updated_at": record["updated_at"].isoformat(),
        "inputs": record.get("inputs", []),
        "outputs": outputs,
        "asset": asset,
    }


# ---------------------------------------------------------------- MiniMax Music 3 generation

MUSIC_MODEL_ID = "mlx-community/MiniMax-Music3-mxfp8"
_music_model = None


def _get_music_model():
    global _music_model
    if _music_model is None:
        from mlx_audio.music.utils import load_model

        _music_model = load_model(MUSIC_MODEL_ID)
        _model_status["minimax_music3"] = "ready"
    return _music_model


def _run_music_generation(job_id: str, prompt: str, lyrics: str, duration: float, seed: int) -> None:
    from mlx_audio.audio_io import write as audio_write

    record = _jobs[job_id]
    model = _get_music_model()

    record["progress_detail"] = "generating music"
    chunks = []
    sample_rate = None
    for result in model.generate(
        text=prompt,
        lyrics=lyrics,
        steps=30,
        seed=seed,
        duration=duration,
    ):
        if sample_rate is None:
            sample_rate = result.sample_rate
        chunks.append(result.audio)
        record["progress_detail"] = f"generated {len(chunks)} chunk(s)"

    if not chunks or sample_rate is None:
        raise RuntimeError("music generation produced no audio")

    import mlx.core as mx

    audio = chunks[0] if len(chunks) == 1 else mx.concatenate(chunks, axis=0)
    out_path = ASSET_ROOT / f"{_new_asset_id()}_generation.wav"
    audio_write(out_path, audio, sample_rate)

    data = out_path.read_bytes()
    asset = _store_asset(data, "generation.wav", "audio/wav")
    link = {"name": "output", "position": 0, "asset": asset.model_dump()}
    record["outputs"] = [link]


def _run_generation(job_id: str) -> None:
    record = _jobs[job_id]
    params = record["parameters"]
    _run_music_generation(
        job_id,
        prompt=params["prompt"],
        lyrics=params.get("lyrics") or "[instrumental]",
        duration=params.get("duration_seconds", 30),
        seed=params.get("seed", 0),
    )


@app.post("/v1/jobs/generation", status_code=202)
async def submit_generation(request: GenerationRequest) -> dict:
    seed = request.seed
    if seed is None:
        seed = secrets.randbelow(SEED_SPACE)

    job_id = _new_job_id()
    _jobs[job_id] = {
        "id": job_id,
        "kind": "generation",
        "state": JobState.QUEUED,
        "parameters": {
            "operation": "text",
            "prompt": request.prompt,
            "lyrics": request.lyrics,
            "preset": request.preset,
            "seed": seed,
            "duration_seconds": request.duration_seconds,
            "steps": 30,
        },
        "created_at": _now(),
        "updated_at": _now(),
        "inputs": [],
        "outputs": [],
    }
    _enqueue_job(job_id, _run_generation)
    return _job_response(job_id)


# ---------------------------------------------------------------- reimagine (reference / remix / repaint)

STT_MODEL_ID = "mlx-community/whisper-large-v3-turbo"
_stt_model = None


def _get_stt_model():
    global _stt_model
    if _stt_model is None:
        from mlx_audio.stt.utils import load_model as load_stt_model

        _stt_model = load_stt_model(STT_MODEL_ID)
        _model_status["whisper_stt"] = "ready"
    return _stt_model


def _extract_lyrics(audio_path: Path) -> str | None:
    """Best-effort lyric extraction from a reference track via Whisper STT."""
    try:
        from mlx_audio.stt.generate import generate_transcription

        segments = generate_transcription(
            model=_get_stt_model(), audio=str(audio_path), verbose=False
        )
        parts = []
        for seg in segments:
            text = getattr(seg, "text", None) or ""
            if isinstance(text, str) and text.strip():
                parts.append(text.strip())
        return " ".join(parts) or None
    except Exception:  # noqa: BLE001 - lyric extraction is best-effort
        return None


def _submit_reimagine_job(
    kind: str,
    prompt: str,
    lyrics: str | None,
    seed: int | None,
    source_asset_id: str,
    extra_params: dict[str, Any],
) -> dict:
    """Create a reimagine job whose source audio feeds lyric extraction."""
    seed = seed if seed is not None else secrets.randbelow(SEED_SPACE)

    job_id = _new_job_id()
    _jobs[job_id] = {
        "id": job_id,
        "kind": kind,
        "state": JobState.QUEUED,
        "parameters": {
            "operation": kind,
            "prompt": prompt,
            "lyrics": lyrics,
            "seed": seed,
            "source_asset_id": source_asset_id,
            **extra_params,
        },
        "created_at": _now(),
        "updated_at": _now(),
        "inputs": [
            {
                "name": "source",
                "position": 0,
                "asset": _assets[source_asset_id]["record"].model_dump(),
            }
        ],
        "outputs": [],
    }
    _enqueue_job(job_id, _run_reimagine)
    return _job_response(job_id)


def _run_reimagine(job_id: str) -> None:
    record = _jobs[job_id]
    params = record["parameters"]
    source_path = _get_asset_path(params["source_asset_id"])

    lyrics = params.get("lyrics")
    if not lyrics:
        record["progress_detail"] = "extracting lyrics from source"
        lyrics = _extract_lyrics(source_path)
    lyrics = lyrics or "[instrumental]"

    if params["operation"] == "repaint":
        _run_repaint(job_id, source_path, lyrics)
    else:
        # reference-generation / remix: prompt-driven re-generation informed
        # by the extracted lyrics; the local model cannot condition on audio.
        _run_music_generation(
            job_id,
            prompt=params["prompt"],
            lyrics=lyrics,
            duration=params.get("duration_seconds", 30),
            seed=params.get("seed", 0),
        )


_CROSSFADE_SECONDS = 0.05


def _as_frames_channels(audio) :  # noqa: ANN001 - numpy array from mlx/soundfile
    import numpy as np

    array = np.asarray(audio, dtype=np.float32)
    if array.ndim == 1:
        return array[:, np.newaxis]
    if array.shape[0] < array.shape[1]:  # (channels, samples) -> (samples, channels)
        return array.T
    return array


def _run_repaint(job_id: str, source_path: Path, lyrics: str) -> None:
    import mlx.core as mx
    import numpy as np
    import soundfile as sf
    from mlx_audio.audio_io import write as audio_write

    record = _jobs[job_id]
    params = record["parameters"]
    start = max(0.0, float(params["start_seconds"]))
    end = max(start, float(params["end_seconds"]))
    if end <= start:
        raise HTTPException(422, "end_seconds must be greater than start_seconds")

    record["progress_detail"] = "loading source audio"
    source, source_rate = sf.read(str(source_path), dtype="float32", always_2d=True)
    source_length = source.shape[0] / source_rate
    end = min(end, source_length)
    if end <= start:
        raise HTTPException(422, "repaint range is empty after clamping to source length")

    record["progress_detail"] = "generating replacement segment"
    model = _get_music_model()
    chunks = []
    model_rate = None
    for result in model.generate(
        text=params["prompt"],
        lyrics=lyrics,
        steps=30,
        seed=params.get("seed", 0),
        duration=end - start,
    ):
        if model_rate is None:
            model_rate = result.sample_rate
        chunks.append(result.audio)
    if not chunks or model_rate is None:
        raise RuntimeError("repaint generation produced no audio")
    replacement = _as_frames_channels(chunks[0] if len(chunks) == 1 else mx.concatenate(chunks, axis=0))

    if model_rate != source_rate:
        import librosa

        replacement = librosa.resample(
            replacement.T, orig_sr=model_rate, target_sr=source_rate
        ).T
    replacement = replacement[: int((end - start) * source_rate)]

    # Match channel count between source and replacement.
    if replacement.shape[1] != source.shape[1]:
        if replacement.shape[1] == 1:
            replacement = np.repeat(replacement, source.shape[1], axis=1)
        else:
            replacement = replacement[:, :1].mean(axis=1, keepdims=True)
            if source.shape[1] > 1:
                replacement = np.repeat(replacement, source.shape[1], axis=1)

    record["progress_detail"] = "splicing repaint"
    fade = int(_CROSSFADE_SECONDS * source_rate)
    start_idx = int(start * source_rate)
    end_idx = start_idx + replacement.shape[0]

    output = source.copy()
    segment = replacement
    if fade > 0 and start_idx > 0:
        overlap = min(fade, output.shape[0] - start_idx, segment.shape[0])
        ramp = np.linspace(0.0, 1.0, overlap, dtype=np.float32)[:, np.newaxis]
        blended = output[start_idx : start_idx + overlap] * (1 - ramp) + segment[:overlap] * ramp
        output[start_idx : start_idx + overlap] = blended
        segment = segment[overlap:]
        start_idx += overlap
    if fade > 0 and end_idx < output.shape[0]:
        overlap = min(fade, output.shape[0] - end_idx, segment.shape[0])
        ramp = np.linspace(1.0, 0.0, overlap, dtype=np.float32)[:, np.newaxis]
        blended = segment[-overlap:] * ramp + output[end_idx : end_idx + overlap] * (1 - ramp)
        output[end_idx : end_idx + overlap] = blended
        segment = segment[:-overlap]

    tail = start_idx + segment.shape[0]
    output[start_idx:tail] = segment
    out_path = ASSET_ROOT / f"{job_id}_repaint.wav"
    audio_write(out_path, output.squeeze(), source_rate)

    data = out_path.read_bytes()
    asset = _store_asset(data, "repaint.wav", "audio/wav")
    link = {"name": "output", "position": 0, "asset": asset.model_dump()}
    record["outputs"] = [link]
    record["progress_detail"] = f"repainted {end - start:.1f}s of source"


@app.post("/v1/jobs/reference-generation", status_code=202)
async def submit_reference_generation(request: ReferenceGenerationRequest) -> dict:
    _get_asset_path(request.reference_asset_id)  # 404 early for unknown assets
    return _submit_reimagine_job(
        kind="reference-generation",
        prompt=request.prompt,
        lyrics=request.lyrics,
        seed=request.seed,
        source_asset_id=request.reference_asset_id,
        extra_params={
            "duration_seconds": request.duration_seconds,
            "preset": request.preset,
        },
    )


@app.post("/v1/jobs/remix", status_code=202)
async def submit_remix(request: RemixRequest) -> dict:
    _get_asset_path(request.source_asset_id)  # 404 early for unknown assets
    return _submit_reimagine_job(
        kind="remix",
        prompt=request.prompt,
        lyrics=request.lyrics,
        seed=request.seed,
        source_asset_id=request.source_asset_id,
        extra_params={
            "duration_seconds": 30,
            "preset": request.preset,
            "source_strength": request.source_strength,
        },
    )


@app.post("/v1/jobs/repaint", status_code=202)
async def submit_repaint(request: RepaintRequest) -> dict:
    if request.end_seconds <= request.start_seconds:
        raise HTTPException(422, "end_seconds must be greater than start_seconds")
    _get_asset_path(request.source_asset_id)  # 404 early for unknown assets
    return _submit_reimagine_job(
        kind="repaint",
        prompt=request.prompt,
        lyrics=request.lyrics,
        seed=request.seed,
        source_asset_id=request.source_asset_id,
        extra_params={
            "start_seconds": request.start_seconds,
            "end_seconds": request.end_seconds,
            "repaint_strength": request.repaint_strength,
        },
    )


# ---------------------------------------------------------------- vocal swap (MLX-RVC)

RVC_WEIGHTS_ID = "lexandstuff/rvc-mlx-weights"
VOICE_MODEL_ROOT = DATA_ROOT / "voice-models"
VOICE_MODEL_ROOT.mkdir(parents=True, exist_ok=True)
_rvc_pipeline = None


def _get_rvc_pipeline():
    global _rvc_pipeline
    if _rvc_pipeline is None:
        from huggingface_hub import hf_hub_download
        from mlx_rvc import RVCPipeline

        weights = hf_hub_download(
            repo_id=RVC_WEIGHTS_ID,
            filename="v2/f0G48k.safetensors",
        )
        _rvc_pipeline = RVCPipeline.from_pretrained(weights)
        _model_status["mlx_rvc"] = "ready"
    return _rvc_pipeline


def _resolve_voice_model(name: str) -> Path:
    candidate = VOICE_MODEL_ROOT / f"{name}.safetensors"
    if candidate.exists():
        return candidate
    candidate = VOICE_MODEL_ROOT / f"{name}.pth"
    if candidate.exists():
        return candidate
    raise HTTPException(404, f"voice model {name!r} not found in {VOICE_MODEL_ROOT}")


def _run_vocal_swap(job_id: str) -> None:
    record = _jobs[job_id]
    params = record["parameters"]

    pipeline = _get_rvc_pipeline()
    if pipeline is None:
        raise RuntimeError("RVC pipeline unavailable")

    record["progress_detail"] = "converting vocals"
    pipeline.convert(
        input_path=params["source_path"],
        output_path=params["out_path"],
        f0_shift=params.get("pitch_shift", 0),
        f0_method="rmvpe",
        index_rate=params.get("index_rate", 0.0),
    )

    data = Path(params["out_path"]).read_bytes()
    asset = _store_asset(data, "vocal-swap.wav", "audio/wav")
    link = {"name": "output", "position": 0, "asset": asset.model_dump()}
    record["outputs"] = [link]


@app.post("/v1/jobs/vocal-swap", status_code=202)
async def submit_vocal_swap(request: VocalSwapRequest) -> dict:
    source_path = _get_asset_path(request.source_asset_id)
    voice_path = _resolve_voice_model(request.voice_model)

    job_id = _new_job_id()
    out_path = ASSET_ROOT / f"{job_id}_vocalswap.wav"
    _jobs[job_id] = {
        "id": job_id,
        "kind": "vocal-swap",
        "state": JobState.QUEUED,
        "parameters": {
            "operation": "vocal-swap",
            "voice_model": request.voice_model,
            "pitch_shift": request.pitch_shift,
            "index_rate": request.index_rate,
            "source_path": str(source_path),
            "out_path": str(out_path),
        },
        "created_at": _now(),
        "updated_at": _now(),
        "inputs": [
            {
                "name": "source",
                "position": 0,
                "asset": _assets[request.source_asset_id]["record"].model_dump(),
            }
        ],
        "outputs": [],
    }
    _enqueue_job(job_id, _run_vocal_swap)
    return _job_response(job_id)


# ---------------------------------------------------------------- stem split (SAM-Audio)

SAM_MODEL_ID = "mlx-community/sam-audio-large"
_sam_model = None
_sam_processor = None


def _get_sam_models():
    global _sam_model, _sam_processor
    if _sam_model is None:
        from mlx_audio.sts import SAMAudio, SAMAudioProcessor

        _sam_processor = SAMAudioProcessor.from_pretrained(SAM_MODEL_ID)
        _sam_model = SAMAudio.from_pretrained(SAM_MODEL_ID)
        _model_status["sam_audio"] = "ready"
    return _sam_model, _sam_processor


def _run_stem_split(job_id: str) -> None:
    import mlx.core as mx
    from mlx_audio.sts import save_audio

    record = _jobs[job_id]
    params = record["parameters"]

    model, processor = _get_sam_models()
    if model is None:
        raise RuntimeError("SAM-Audio unavailable")

    record["progress_detail"] = "loading audio"
    batch = processor(
        descriptions=[params["description"]],
        audios=[params["source_path"]],
    )

    record["progress_detail"] = "separating stems"
    result = model.separate_long(
        audios=batch.audios,
        descriptions=batch.descriptions,
        chunk_seconds=10.0,
        overlap_seconds=3.0,
        ode_decode_chunk_size=50,
    )

    record["progress_detail"] = "saving stems"
    outputs = []
    for name, arrays in (
        ("target", result.target),
        ("residual", result.residual),
    ):
        if not arrays:
            continue
        audio = arrays[0]
        out_path = ASSET_ROOT / f"{job_id}_{name}.wav"
        save_audio(audio, str(out_path), sample_rate=model.sample_rate)
        data = out_path.read_bytes()
        asset = _store_asset(data, f"{name}.wav", "audio/wav")
        outputs.append({"name": name, "position": len(outputs), "asset": asset.model_dump()})

    if not outputs:
        raise RuntimeError("stem separation produced no output")
    record["outputs"] = outputs


@app.post("/v1/jobs/stem-split", status_code=202)
async def submit_stem_split(request: StemSplitRequest) -> dict:
    source_path = _get_asset_path(request.source_asset_id)

    job_id = _new_job_id()
    _jobs[job_id] = {
        "id": job_id,
        "kind": "stem-split",
        "state": JobState.QUEUED,
        "parameters": {
            "operation": "stem-split",
            "description": request.description,
            "source_path": str(source_path),
        },
        "created_at": _now(),
        "updated_at": _now(),
        "inputs": [
            {
                "name": "source",
                "position": 0,
                "asset": _assets[request.source_asset_id]["record"].model_dump(),
            }
        ],
        "outputs": [],
    }
    _enqueue_job(job_id, _run_stem_split)
    return _job_response(job_id)


# ---------------------------------------------------------------- transcription (Basic Pitch)

BASIC_PITCH_MODEL = (
    Path(__file__).resolve().parent.parent
    / ".venv" / "lib" / "python3.12" / "site-packages"
    / "basic_pitch" / "saved_models" / "icassp_2022" / "nmp.onnx"
)


def _run_transcription(job_id: str) -> None:
    from basic_pitch.inference import predict

    record = _jobs[job_id]
    params = record["parameters"]

    record["progress_detail"] = "transcribing audio"
    model_output, midi_data, note_events = predict(
        params["source_path"],
        str(BASIC_PITCH_MODEL),
        onset_threshold=0.4,
        frame_threshold=0.3,
        minimum_note_length=100.0,
    )

    if not note_events:
        raise RuntimeError("no note events detected")

    midi_path = ASSET_ROOT / f"{job_id}_transcription.mid"
    midi_data.write(str(midi_path))
    data = midi_path.read_bytes()
    asset = _store_asset(data, "transcription.mid", "audio/midi")
    link = {"name": "output", "position": 0, "asset": asset.model_dump()}
    record["outputs"] = [link]
    record["progress_detail"] = f"transcribed {len(note_events)} notes"


@app.post("/v1/jobs/transcription", status_code=202)
async def submit_transcription(
    audio_file: UploadFile = File(...),
    instruments: list[str] | None = None,
    detect_tempo: str = Form("true"),
) -> dict:
    data = await audio_file.read()
    source = _store_asset(data, audio_file.filename or "upload.wav", "audio/wav")

    job_id = _new_job_id()
    _jobs[job_id] = {
        "id": job_id,
        "kind": "transcription",
        "state": JobState.QUEUED,
        "parameters": {
            "operation": "transcription",
            "instruments": instruments or ["all"],
            "detect_tempo": detect_tempo,
            "source_path": str(_get_asset_path(source.id)),
        },
        "created_at": _now(),
        "updated_at": _now(),
        "inputs": [
            {
                "name": "source",
                "position": 0,
                "asset": source.model_dump(),
            }
        ],
        "outputs": [],
    }
    _enqueue_job(job_id, _run_transcription)
    return _job_response(job_id)


# ---------------------------------------------------------------- job polling

@app.get("/v1/jobs")
def list_jobs() -> list[dict]:
    return [_job_response(j) for j in _jobs]


@app.get("/v1/jobs/{job_id}")
def get_job(job_id: str) -> dict:
    if job_id not in _jobs:
        raise HTTPException(404, f"job {job_id} not found")
    return _job_response(job_id)


@app.post("/v1/jobs/{job_id}/cancel")
def cancel_job(job_id: str) -> dict:
    if job_id not in _jobs:
        raise HTTPException(404, f"job {job_id} not found")
    record = _jobs[job_id]
    if record["state"] in (JobState.SUCCEEDED, JobState.FAILED):
        raise HTTPException(409, f"job already {record['state']}")
    record["state"] = "cancelled"
    record["updated_at"] = _now()
    return {"status": "cancelled"}


# ---------------------------------------------------------------- run

def run() -> None:
    import uvicorn

    uvicorn.run(
        "local_inference.main:app",
        host="127.0.0.1",
        port=8902,
        log_level="info",
        reload=False,
    )


if __name__ == "__main__":
    run()
