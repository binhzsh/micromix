from __future__ import annotations

import asyncio
from contextlib import asynccontextmanager
from datetime import datetime, timedelta, timezone
import uuid
from pathlib import Path

from fastapi import FastAPI, File, Form, HTTPException, Request, UploadFile, status
from fastapi.responses import FileResponse

from .config import Settings
from .adapters import ACEClient, GPUClient, MuScriptorClient, RVCClient
from .coordinator import Coordinator, Dispatcher
from .generation import resolve_variation_seeds
from .models import (
    AssetRecord,
    CapabilitiesResponse,
    GenerationOperation,
    GenerationPreset,
    GenerationRequest,
    JobKind,
    JobRecord,
    ReferenceGenerationRequest,
    RemixRequest,
    RepaintRequest,
    VocalConversionRequest,
)
from .store import InputAssetBinding, JobStore
from .voice_profiles import VoiceProfileError, VoiceProfileRegistry


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


async def _read_audio_upload(audio_file: UploadFile, max_upload_mib: int) -> bytes:
    data = await audio_file.read()
    if not data:
        raise HTTPException(status_code=400, detail="audio file is empty")
    if len(data) > max_upload_mib * 1024 * 1024:
        raise HTTPException(
            status_code=413,
            detail=f"audio file exceeds {max_upload_mib} MiB",
        )
    return data


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
    rvc = RVCClient(resolved.rvc_url)
    voice_profiles = VoiceProfileRegistry(resolved.voice_profile_root)
    coordinator = Coordinator(store, gpu, ace, muscriptor, rvc)
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
            await rvc.aclose()
            await store.close()

    app = FastAPI(title="micromix-api", version="0.2.0", lifespan=lifespan)

    @app.get("/v1/health")
    async def health() -> dict:
        if start_dispatcher:
            gpu_status, ace_status, muscriptor_status, rvc_status = await asyncio.gather(
                gpu.status(),
                ace.health(),
                muscriptor.health(),
                rvc.health(),
            )
        else:
            gpu_status = {"status": "unknown", "free_mib": None, "holders": []}
            ace_status = "cold"
            muscriptor_status = "cold"
            rvc_status = "cold"
        return {
            "service": "micromix-api",
            "status": "ok",
            "database": "ready",
            "gpu": gpu_status,
            "workers": {
                "ace_step": {"status": ace_status},
                "muscriptor": {"status": muscriptor_status},
                "rvc": {"status": rvc_status},
            },
        }

    @app.get("/v1/capabilities", response_model=CapabilitiesResponse)
    async def capabilities() -> CapabilitiesResponse:
        return CapabilitiesResponse(
            generation_presets=PRESETS,
            transcription_instruments=(await muscriptor.instruments()) if start_dispatcher else [],
        )

    async def resolve_audio_asset(asset_id: str) -> AssetRecord:
        value = await store.get_asset(asset_id)
        if value is None:
            raise HTTPException(status_code=404, detail="asset not found")
        record, _ = value
        if not (
            record.media_type.startswith("audio/")
            or record.media_type == "application/octet-stream"
        ):
            raise HTTPException(
                status_code=422,
                detail="source asset must contain audio",
            )
        return record

    async def submit_reimagine(
        payload: ReferenceGenerationRequest | RemixRequest | RepaintRequest,
        operation: GenerationOperation,
        asset_field: str,
        input_name: str,
    ) -> JobRecord:
        asset_id = getattr(payload, asset_field)
        await resolve_audio_asset(asset_id)
        parameters = payload.model_dump(
            exclude_none=True,
            exclude={asset_field},
        )
        parameters.update(
            operation=operation.value,
            seeds=resolve_variation_seeds(
                payload.seed,
                payload.variation_count,
            ),
            _upstream_recovery_count=0,
        )
        job = await store.create_job(
            JobKind.generation,
            parameters,
            inputs=[InputAssetBinding(asset_id, input_name)],
        )
        if start_dispatcher:
            await dispatcher.enqueue(job.id)
        return job

    @app.post(
        "/v1/jobs/generation",
        response_model=JobRecord,
        status_code=status.HTTP_202_ACCEPTED,
    )
    async def submit_generation(payload: GenerationRequest) -> JobRecord:
        job = await store.create_job(
            JobKind.generation,
            {
                **payload.model_dump(exclude_none=True),
                "operation": GenerationOperation.text.value,
                "seeds": resolve_variation_seeds(
                    payload.seed,
                    payload.variation_count,
                ),
                "_upstream_recovery_count": 0,
            },
        )
        if start_dispatcher:
            await dispatcher.enqueue(job.id)
        return job

    @app.post(
        "/v1/jobs/reference-generation",
        response_model=JobRecord,
        status_code=status.HTTP_202_ACCEPTED,
    )
    async def submit_reference_generation(
        payload: ReferenceGenerationRequest,
    ) -> JobRecord:
        return await submit_reimagine(
            payload,
            GenerationOperation.reference,
            "reference_asset_id",
            "reference",
        )

    @app.post(
        "/v1/jobs/remix",
        response_model=JobRecord,
        status_code=status.HTTP_202_ACCEPTED,
    )
    async def submit_remix(payload: RemixRequest) -> JobRecord:
        return await submit_reimagine(
            payload,
            GenerationOperation.remix,
            "source_asset_id",
            "source",
        )

    @app.post(
        "/v1/jobs/repaint",
        response_model=JobRecord,
        status_code=status.HTTP_202_ACCEPTED,
    )
    async def submit_repaint(payload: RepaintRequest) -> JobRecord:
        return await submit_reimagine(
            payload,
            GenerationOperation.repaint,
            "source_asset_id",
            "source",
        )

    @app.post(
        "/v1/jobs/vocal-conversion",
        response_model=JobRecord,
        status_code=status.HTTP_202_ACCEPTED,
    )
    async def submit_vocal_conversion(payload: VocalConversionRequest) -> JobRecord:
        try:
            profile = voice_profiles.resolve(payload.voice_profile_id)
        except VoiceProfileError as exc:
            raise HTTPException(status_code=422, detail=str(exc)) from exc
        await resolve_audio_asset(payload.source_asset_id)
        source = await store.get_asset(payload.source_asset_id)
        assert source is not None
        _, source_path = source
        parameters = {
            "voice_profile_id": profile.id,
            "voice_profile_revision": profile.revision,
            "pitch_shift_semitones": payload.pitch_shift_semitones,
            "f0_method": payload.f0_method,
            "_source_path": str(source_path),
            "_model_path": str(profile.model_path),
        }
        if profile.index_path is not None:
            parameters["_index_path"] = str(profile.index_path)
        job = await store.create_job(
            JobKind.vocal_conversion,
            parameters,
            inputs=[InputAssetBinding(payload.source_asset_id, "source")],
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
        data = await _read_audio_upload(audio_file, resolved.max_upload_mib)
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

    @app.post(
        "/v1/assets",
        response_model=AssetRecord,
        status_code=status.HTTP_201_CREATED,
    )
    async def upload_asset(audio_file: UploadFile = File(...)) -> AssetRecord:
        data = await _read_audio_upload(audio_file, resolved.max_upload_mib)
        filename = Path(audio_file.filename or "input.wav").name
        import_dir = resolved.asset_root / "imports" / uuid.uuid4().hex
        import_dir.mkdir(parents=True, exist_ok=True)
        import_path = import_dir / filename
        import_path.write_bytes(data)
        try:
            return await store.create_asset(
                import_path,
                audio_file.content_type or "application/octet-stream",
                filename,
            )
        except Exception:
            import_path.unlink(missing_ok=True)
            import_dir.rmdir()
            raise

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
