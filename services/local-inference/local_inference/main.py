"""Durable, loopback-only inference API for the native Mac app."""
from __future__ import annotations

import asyncio
import hashlib
import json
import os
import re
import secrets
import subprocess
import tempfile
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Literal

from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from fastapi.responses import FileResponse
from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator

from .runtime import Runtime

SERVICE_ROOT = Path(__file__).resolve().parent.parent
DATA_ROOT = Path(os.environ.get("MICROMIX_DATA_ROOT", SERVICE_ROOT / "data"))
MAX_UPLOAD_BYTES = 200 * 1024 * 1024
VOICE_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$")


class MusicRequest(BaseModel):
    model_config = ConfigDict(extra="forbid", allow_inf_nan=False)
    prompt: str = Field(min_length=1, max_length=4000)
    lyrics: str | None = Field(default=None, max_length=50_000)
    preset: Literal["turbo", "quality", "minimax-cover"] = "turbo"
    seed: int | None = Field(default=None, ge=0, le=4_294_967_295)
    variation_count: int = Field(default=1, ge=1, le=4)
    vocal_language: Literal["en", "vi"] | None = None
    bpm: int | None = Field(default=None, ge=30, le=300)
    key: str | None = Field(default=None, max_length=32)
    time_signature: Literal["2", "3", "4", "6"] | None = None

    @field_validator("prompt")
    @classmethod
    def nonblank_prompt(cls, value: str) -> str:
        if not value.strip():
            raise ValueError("prompt must not be blank")
        return value.strip()

    @model_validator(mode="after")
    def supported_controls(self):
        if self.preset == "minimax-cover" and self.variation_count != 1:
            raise ValueError("MiniMax supports one variation; use Turbo or Quality for alternatives")
        if self.preset == "minimax-cover" and any(
            value is not None for value in
            (self.vocal_language, self.bpm, self.key, self.time_signature)
        ):
            raise ValueError("Use Turbo or Quality for musical metadata and vocal language controls")
        return self


class GenerationRequest(MusicRequest):
    duration_seconds: float = Field(default=30, ge=10, le=600)


class ReferenceGenerationRequest(GenerationRequest):
    reference_asset_id: str = Field(min_length=1)


class RemixRequest(MusicRequest):
    source_asset_id: str = Field(min_length=1)
    source_strength: float = Field(default=0.6, ge=0, le=1)


class RepaintRequest(MusicRequest):
    source_asset_id: str = Field(min_length=1)
    start_seconds: float = Field(ge=0)
    end_seconds: float = Field(gt=0)
    repaint_strength: float = Field(default=0.5, ge=0, le=1)

    @model_validator(mode="after")
    def valid_interval(self):
        if not 3 <= self.end_seconds - self.start_seconds <= 90:
            raise ValueError("repaint interval must be 3–90 seconds")
        return self


class VocalSwapRequest(BaseModel):
    model_config = ConfigDict(extra="forbid", allow_inf_nan=False)
    source_asset_id: str = Field(min_length=1)
    voice_model: str = Field(pattern=VOICE_ID.pattern)
    pitch_shift: int = Field(default=0, ge=-24, le=24)
    index_rate: float = Field(default=0.5, ge=0, le=1)


class StemSplitRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")
    source_asset_id: str = Field(min_length=1)
    description: str = Field(min_length=1, max_length=1000)

    @field_validator("description")
    @classmethod
    def nonblank_description(cls, value: str) -> str:
        if not value.strip():
            raise ValueError("describe the stem to separate")
        return value.strip()


def worker_command(manifest_path: Path) -> list[str]:
    manifest = json.loads(manifest_path.read_text())
    operation = manifest["operation"]
    if operation == "transcription":
        environment = ".venv-muscriptor"
    elif operation in {"generation", "reference-generation", "remix", "repaint"} and manifest["parameters"].get("preset") != "minimax-cover":
        environment = ".venv-ace"
    else:
        environment = ".venv-mlx"
    executable = SERVICE_ROOT / environment / "bin" / "python"
    if not executable.is_file():
        raise RuntimeError(
            f"Local model environment {environment} is missing. "
            "Run bash scripts/setup-local-models.sh from the Micromix repository."
        )
    # A file entry point avoids relying on cwd or a mutable PYTHONPATH.
    return [str(executable), str(Path(__file__).with_name("worker.py")), str(manifest_path)]


def _hash_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    return 'sha256:' + digest.hexdigest()


def _voice_files(root: Path, name: str) -> tuple[Path, Path | None]:
    if not VOICE_ID.fullmatch(name):
        raise HTTPException(422, "invalid voice model ID")
    root = root.resolve()
    for suffix in ('.safetensors', '.pth'):
        path = (root / (name + suffix)).resolve()
        if path.is_relative_to(root) and path.is_file():
            index = (root / (name + '.index')).resolve()
            if not index.is_relative_to(root):
                raise HTTPException(422, "voice index must stay inside the private model root")
            return path, index if index.is_file() else None
    raise HTTPException(404, "Private voice model is unavailable; add its .safetensors or .pth file to data/voice-models")


def _voice_names(root: Path) -> list[str]:
    names = {p.stem for p in root.glob('*.safetensors')} | {p.stem for p in root.glob('*.pth')}
    available = []
    for name in sorted(names):
        try:
            _voice_files(root, name)
        except HTTPException:
            continue
        available.append(name)
    return available


def create_app(
    root: Path | None = None, *, start_worker: bool = True,
    max_upload_bytes: int = MAX_UPLOAD_BYTES, command_factory=None,
) -> FastAPI:
    root = Path(root if root is not None else DATA_ROOT)
    voice_root = root / 'voice-models'

    @asynccontextmanager
    async def lifespan(app: FastAPI):
        voice_root.mkdir(parents=True, exist_ok=True)
        runtime = Runtime(root, command_factory=command_factory or worker_command)
        app.state.runtime = runtime
        # Exclusive runtime ownership makes leftovers from previous uploads safe to remove.
        for temporary_upload in root.glob("*.upload"):
            temporary_upload.unlink(missing_ok=True)
        try:
            runtime.prune(retention_days=7)
            if start_worker:
                runtime.start()
            yield
        finally:
            runtime.close()

    app = FastAPI(title='Micromix local inference', version='0.2.0', lifespan=lifespan)

    def runtime() -> Runtime:
        return app.state.runtime

    def job_or_404(job_id: str) -> dict:
        try:
            return runtime().get_job(job_id)
        except KeyError:
            raise HTTPException(404, 'job not found') from None

    def source_link(asset_id: str, name: str = 'source') -> dict:
        try:
            path = runtime().asset_path(asset_id)
            asset = runtime().get_asset(asset_id)
        except KeyError:
            raise HTTPException(404, 'source asset not found') from None
        if not path.is_file():
            raise HTTPException(404, 'source audio file is missing')
        if not asset['media_type'].startswith('audio/'):
            raise HTTPException(422, 'source asset must contain audio')
        return {'name': name, 'position': 0, 'asset': asset}

    async def upload(audio_file: UploadFile) -> dict:
        filename = Path((audio_file.filename or 'upload.wav').replace('\\', '/')).name
        if filename in {'.', '..', ''}:
            filename = 'upload.wav'
        media_type = audio_file.content_type or 'application/octet-stream'
        try:
            if media_type == 'application/octet-stream':
                import mimetypes
                media_type = mimetypes.guess_type(filename)[0] or 'audio/wav'
            if not media_type.startswith('audio/'):
                raise HTTPException(422, 'upload an audio file')
            with tempfile.NamedTemporaryFile(dir=root, suffix='.upload') as stream:
                size = 0
                while chunk := await audio_file.read(1024 * 1024):
                    size += len(chunk)
                    if size > max_upload_bytes:
                        raise HTTPException(413, 'audio file exceeds upload limit')
                    stream.write(chunk)
                if not size:
                    raise HTTPException(422, 'audio file is empty')
                stream.flush()
                return await asyncio.to_thread(
                    runtime().add_asset_file, Path(stream.name), filename, media_type)
        finally:
            await audio_file.close()

    def music(payload: MusicRequest, operation: str, asset_id: str | None = None) -> dict:
        if operation != 'generation' and payload.preset == 'minimax-cover':
            raise HTTPException(422, 'Reference, Remix and Repaint require the local Turbo or Quality model')
        params = payload.model_dump(exclude_none=True, exclude={'source_asset_id', 'reference_asset_id'})
        seed = payload.seed if payload.seed is not None else secrets.randbelow(2**32)
        params['seed'] = seed
        params['seeds'] = [(seed + index) % 2**32 for index in range(payload.variation_count)]
        params['operation'] = {'generation': 'text', 'reference-generation': 'reference'}.get(operation, operation)
        links = [source_link(asset_id, 'reference' if operation == 'reference-generation' else 'source')] if asset_id else []
        private = {'source_path': str(runtime().asset_path(asset_id))} if asset_id else {}
        return runtime().submit(operation, params, links, worker_parameters=private)

    @app.get('/v1/health')
    def health():
        models = {}
        for environment, packages, names in [
            ('.venv-ace', ['acestep', 'torch'], ['ace_step']),
            ('.venv-muscriptor', ['muscriptor', 'torch'], ['muscriptor']),
            ('.venv-mlx', ['mlx_audio', 'mlx_rvc'],
             ['minimax_music3', 'mlx_rvc', 'sam_audio']),
        ]:
            executable = SERVICE_ROOT / environment / 'bin/python'
            status = 'unavailable'
            if executable.is_file():
                try:
                    result = subprocess.run(
                        [str(executable), '-c',
                         'import importlib.util,sys; '
                         'sys.exit(not all(importlib.util.find_spec(p) is not None '
                         'for p in sys.argv[1:]))', *packages],
                        capture_output=True, timeout=5, check=False)
                    if result.returncode == 0:
                        status = 'dependencies_present_weights_unchecked'
                except (OSError, subprocess.TimeoutExpired):
                    pass
            models.update({name: status for name in names})
        return {'service': 'micromix-local-inference', 'status': 'ready',
                'database': 'ready', 'models': models}

    @app.get('/v1/capabilities')
    def capabilities():
        from .engines import TRANSCRIPTION_INSTRUMENTS
        return {'generation_presets': [
            {'id': 'turbo', 'label': 'XL Turbo', 'model': 'acestep-v15-xl-turbo', 'inference_steps': 8},
            {'id': 'quality', 'label': 'XL Quality', 'model': 'acestep-v15-xl-sft', 'inference_steps': 50},
            {'id': 'minimax-cover', 'label': 'MiniMax (text only)', 'model': 'MiniMax-Music3-mxfp8', 'inference_steps': 30},
        ], 'transcription_instruments': list(TRANSCRIPTION_INSTRUMENTS),
            'vocal_models': _voice_names(voice_root), 'stem_targets': ['vocals', 'drums', 'bass', 'other'],
            'reimagine_modes': ['reference-generation', 'remix', 'repaint']}

    @app.post('/v1/assets')
    async def upload_asset(audio_file: UploadFile = File(...)):
        return await upload(audio_file)

    @app.get('/v1/assets/{asset_id}')
    def download_asset(asset_id: str):
        try:
            asset = runtime().get_asset(asset_id)
            path = runtime().asset_path(asset_id)
        except KeyError:
            raise HTTPException(404, 'asset not found') from None
        if not path.is_file():
            raise HTTPException(404, 'asset file is missing')
        return FileResponse(path, media_type=asset['media_type'], filename=asset['filename'])

    @app.post('/v1/jobs/generation', status_code=202)
    async def generation(payload: GenerationRequest):
        return music(payload, 'generation')

    @app.post('/v1/jobs/reference-generation', status_code=202)
    async def reference(payload: ReferenceGenerationRequest):
        return music(payload, 'reference-generation', payload.reference_asset_id)

    @app.post('/v1/jobs/remix', status_code=202)
    async def remix(payload: RemixRequest):
        return music(payload, 'remix', payload.source_asset_id)

    @app.post('/v1/jobs/repaint', status_code=202)
    async def repaint(payload: RepaintRequest):
        return music(payload, 'repaint', payload.source_asset_id)

    @app.post('/v1/jobs/transcription', status_code=202)
    async def transcription(
        audio_file: UploadFile = File(...), instruments: list[str] = Form(default=[]),
        detect_tempo: Literal['true', 'false', 'best-effort'] = Form('true'),
    ):
        from .engines import TRANSCRIPTION_INSTRUMENTS
        if any(instrument not in TRANSCRIPTION_INSTRUMENTS for instrument in instruments):
            raise HTTPException(422, 'unknown transcription instrument')
        source = await upload(audio_file)
        params = {'operation': 'transcription', 'instruments': instruments,
                  'detect_tempo': detect_tempo != 'false', 'filename': source['filename']}
        return runtime().submit('transcription', params, [{'name': 'source', 'position': 0, 'asset': source}],
                                worker_parameters={'source_path': str(runtime().asset_path(source['id']))})

    @app.post('/v1/jobs/vocal-swap', status_code=202)
    async def vocal_swap(payload: VocalSwapRequest):
        link = source_link(payload.source_asset_id)
        model_path, index_path = _voice_files(voice_root, payload.voice_model)
        revision = await asyncio.to_thread(_hash_file, model_path)
        params = {'operation': 'vocal-swap', 'voice_model': payload.voice_model,
                  'voice_model_revision': revision, 'pitch_shift': payload.pitch_shift,
                  'index_rate': payload.index_rate if index_path else 0.0}
        if index_path:
            params['voice_index_revision'] = await asyncio.to_thread(_hash_file, index_path)
        private = {'source_path': str(runtime().asset_path(payload.source_asset_id)),
                   'model_path': str(model_path), 'index_path': str(index_path) if index_path else None,
                   'model_revision': revision}
        return runtime().submit('vocal-swap', params, [link], worker_parameters=private)

    @app.post('/v1/jobs/stem-split', status_code=202)
    async def stem_split(payload: StemSplitRequest):
        link = source_link(payload.source_asset_id)
        return runtime().submit('stem-split', {'operation': 'stem-split', 'description': payload.description}, [link],
                                worker_parameters={'source_path': str(runtime().asset_path(payload.source_asset_id))})

    @app.get('/v1/jobs')
    def jobs():
        return runtime().list_jobs()

    @app.get('/v1/jobs/{job_id}')
    def job(job_id: str):
        return job_or_404(job_id)

    @app.post('/v1/jobs/{job_id}/cancel')
    def cancel(job_id: str):
        job_or_404(job_id)
        return runtime().cancel(job_id)

    return app


app = create_app()


def run():
    import uvicorn
    uvicorn.run('local_inference.main:app', host='127.0.0.1', port=8902, log_level='info')


if __name__ == '__main__':
    run()
