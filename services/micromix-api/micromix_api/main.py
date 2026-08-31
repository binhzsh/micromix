from __future__ import annotations

import asyncio
from contextlib import asynccontextmanager
from datetime import datetime, timedelta, timezone
import uuid
from pathlib import Path

from fastapi import FastAPI, File, Form, HTTPException, Request, UploadFile, status
from fastapi.responses import FileResponse

from .config import Settings
from .adapters import ACEClient, GPUClient, MuScriptorClient
from .coordinator import Coordinator, Dispatcher
from .models import (
    CapabilitiesResponse,
    GenerationPreset,
    GenerationRequest,
    JobKind,
    JobRecord,
)
from .store import JobStore


PRESETS = [
    GenerationPreset(
        id="turbo",
        label="Turbo",
        model="acestep-v15-xl-turbo",
        inference_steps=8,
    ),
    GenerationPreset(
        id="quality",
        label="Quality",
        model="acestep-v15-xl-sft",
        inference_steps=50,
    ),
]


def create_app(
    *,
    settings: Settings | None = None,
    start_dispatcher: bool = True,
) -> FastAPI:
    resolved = settings or Settings.from_env()
    store = JobStore(resolved.database_path, resolved.asset_root)
    gpu = GPUClient(resolved.gpu_router_url)
    ace = ACEClient(resolved.ace_url)
    muscriptor = MuScriptorClient(resolved.muscriptor_url)
    coordinator = Coordinator(store, gpu, ace, muscriptor)
    dispatcher = Dispatcher(coordinator)

    @asynccontextmanager
    async def lifespan(app: FastAPI):
        resolved.upload_root.mkdir(parents=True, exist_ok=True)
        await store.open()
        recovered = await store.recover_jobs()
        await store.prune_assets(
            older_than=datetime.now(timezone.utc) - timedelta(days=resolved.retention_days)
        )
        app.state.settings = resolved
        app.state.store = store
        app.state.start_dispatcher = start_dispatcher
        app.state.dispatcher = dispatcher
        if start_dispatcher:
            dispatcher.start()
            for job_id in recovered:
                await dispatcher.enqueue(job_id)
        try:
            yield
        finally:
            await dispatcher.close()
            await gpu.aclose()
            await ace.aclose()
            await muscriptor.aclose()
            await store.close()

    app = FastAPI(title="micromix-api", version="0.2.0", lifespan=lifespan)

    @app.get("/v1/health")
    async def health() -> dict:
        if start_dispatcher:
            gpu_status, ace_status, muscriptor_status = await asyncio.gather(
                gpu.status(),
                ace.health(),
                muscriptor.health(),
            )
        else:
            gpu_status = {"status": "unknown", "free_mib": None, "holders": []}
            ace_status = "cold"
            muscriptor_status = "cold"
        return {
            "service": "micromix-api",
            "status": "ok",
            "database": "ready",
            "gpu": gpu_status,
            "workers": {
                "ace_step": {"status": ace_status},
                "muscriptor": {"status": muscriptor_status},
            },
        }

    @app.get("/v1/capabilities", response_model=CapabilitiesResponse)
    async def capabilities() -> CapabilitiesResponse:
        return CapabilitiesResponse(
            generation_presets=PRESETS,
            transcription_instruments=(await muscriptor.instruments()) if start_dispatcher else [],
        )

    @app.post(
        "/v1/jobs/generation",
        response_model=JobRecord,
        status_code=status.HTTP_202_ACCEPTED,
    )
    async def submit_generation(payload: GenerationRequest) -> JobRecord:
        job = await store.create_job(
            JobKind.generation,
            payload.model_dump(exclude_none=True),
        )
        if start_dispatcher:
            await dispatcher.enqueue(job.id)
        return job

    @app.post(
        "/v1/jobs/transcription",
        response_model=JobRecord,
        status_code=status.HTTP_202_ACCEPTED,
    )
    async def submit_transcription(
        audio_file: UploadFile = File(...),
        instruments: list[str] = Form(default_factory=list),
        detect_tempo: bool = Form(True),
    ) -> JobRecord:
        data = await audio_file.read()
        if not data:
            raise HTTPException(status_code=400, detail="audio file is empty")
        if len(data) > resolved.max_upload_mib * 1024 * 1024:
            raise HTTPException(
                status_code=413,
                detail=f"audio file exceeds {resolved.max_upload_mib} MiB",
            )
        filename = Path(audio_file.filename or "input.wav").name
        upload_dir = resolved.upload_root / uuid.uuid4().hex
        upload_dir.mkdir(parents=True, exist_ok=True)
        upload_path = upload_dir / filename
        upload_path.write_bytes(data)
        job = await store.create_job(
            JobKind.transcription,
            {
                "filename": filename,
                "instruments": instruments,
                "detect_tempo": detect_tempo,
                "_input_path": str(upload_path),
            },
        )
        if start_dispatcher:
            await dispatcher.enqueue(job.id)
        return job

    @app.get("/v1/jobs", response_model=list[JobRecord])
    async def list_jobs() -> list[JobRecord]:
        return await store.list_jobs()

    @app.get("/v1/jobs/{job_id}", response_model=JobRecord)
    async def get_job(job_id: str) -> JobRecord:
        job = await store.get_job(job_id)
        if job is None:
            raise HTTPException(status_code=404, detail="job not found")
        return job

    @app.post("/v1/jobs/{job_id}/cancel", response_model=JobRecord)
    async def cancel_job(job_id: str) -> JobRecord:
        try:
            return await store.cancel_job(job_id)
        except KeyError as exc:
            raise HTTPException(status_code=404, detail="job not found") from exc

    @app.get("/v1/assets/{asset_id}")
    async def get_asset(asset_id: str, request: Request) -> FileResponse:
        value = await store.get_asset(asset_id)
        if value is None:
            raise HTTPException(status_code=404, detail="asset not found")
        record, path = value
        if not path.is_file():
            raise HTTPException(status_code=404, detail="asset file not found")
        return FileResponse(path, media_type=record.media_type, filename=record.filename)

    return app


app = create_app()
