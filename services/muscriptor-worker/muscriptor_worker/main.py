from __future__ import annotations

import asyncio
import gc
import io
import os
import wave
from collections.abc import Callable
from typing import Protocol

from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from fastapi.responses import Response


class TranscriptionEngine(Protocol):
    def transcribe(self, data: bytes, instruments: list[str], detect_tempo: str) -> bytes: ...

    def release(self) -> None: ...


class MuScriptorEngine:
    def __init__(self) -> None:
        from muscriptor.main import _load_model

        model_path = os.getenv("MUSCRIPTOR_MODEL", "medium")
        device = os.getenv("MUSCRIPTOR_DEVICE", "cuda")
        dtype = os.getenv("MUSCRIPTOR_DTYPE")
        self.model = _load_model(model_path, device, dtype)

    def transcribe(self, data: bytes, instruments: list[str], detect_tempo: str) -> bytes:
        from muscriptor.events import NoteStartEvent, ProgressEvent
        from muscriptor.tokenizer.mt3 import MT3_FULL_PLUS_GROUP_NAMES
        from muscriptor.utils.audio import _read_non_wav_file, _read_wav_file

        try:
            wav_data, sample_rate = _read_wav_file(io.BytesIO(data))
        except (wave.Error, EOFError):
            try:
                wav_data, sample_rate = _read_non_wav_file(io.BytesIO(data))
            except Exception as exc:
                raise ValueError(f"could not decode audio: {exc}") from exc

        unknown = [name for name in instruments if name not in MT3_FULL_PLUS_GROUP_NAMES]
        if unknown:
            raise ValueError(f"unknown instrument name(s): {', '.join(unknown)}")

        audio = (wav_data, sample_rate)
        events = [
            event
            for event in self.model.transcribe(
                audio,
                instruments=instruments or None,
                batch_size=1,
                no_eos_is_ok=True,
            )
            if not isinstance(event, ProgressEvent)
        ]
        grid = self.model.detect_beat_grid_for(audio, detect_tempo)
        if grid:
            grid = grid.with_onset_delay(
                [event.start_time for event in events if isinstance(event, NoteStartEvent)]
            )
        return self.model.events_to_midi_bytes(iter(events), beat_grid=grid)

    def release(self) -> None:
        self.model = None
        gc.collect()
        try:
            import torch

            if torch.cuda.is_available():
                torch.cuda.empty_cache()
                torch.cuda.ipc_collect()
        except Exception:
            pass


def available_instruments() -> list[str]:
    from muscriptor.tokenizer.mt3 import MT3_FULL_PLUS_GROUP_NAMES

    return list(MT3_FULL_PLUS_GROUP_NAMES.keys())


class ModelManager:
    def __init__(
        self,
        factory: Callable[[], TranscriptionEngine] = MuScriptorEngine,
        *,
        instrument_provider: Callable[[], list[str]] = available_instruments,
    ) -> None:
        self.factory = factory
        self.instrument_provider = instrument_provider
        self._engine: TranscriptionEngine | None = None

    @property
    def loaded(self) -> bool:
        return self._engine is not None

    def get(self) -> TranscriptionEngine:
        if self._engine is None:
            self._engine = self.factory()
        return self._engine

    def release(self) -> bool:
        if self._engine is None:
            return False
        engine, self._engine = self._engine, None
        engine.release()
        return True


def create_app(manager: ModelManager | None = None) -> FastAPI:
    app = FastAPI(title="Micromix MuScriptor Worker")
    model_manager = manager or ModelManager()
    operation_lock = asyncio.Lock()

    @app.get("/health")
    async def health() -> dict[str, str | bool]:
        return {"status": "ok", "loaded": model_manager.loaded}

    @app.get("/instruments")
    async def instruments() -> dict[str, list[str]]:
        return {"instruments": model_manager.instrument_provider()}

    @app.post("/transcribe/midi")
    async def transcribe_midi(
        audio_file: UploadFile = File(...),
        instruments: list[str] = Form(default_factory=list),
        detect_tempo: str = Form("best-effort"),
        return_file: bool = Form(False),
    ) -> Response:
        del return_file
        data = await audio_file.read()
        if not data:
            raise HTTPException(status_code=400, detail="no file provided")
        async with operation_lock:
            try:
                midi = await asyncio.to_thread(
                    model_manager.get().transcribe,
                    data,
                    instruments,
                    detect_tempo,
                )
            except ValueError as exc:
                raise HTTPException(status_code=400, detail=str(exc)) from exc
        return Response(
            content=midi,
            media_type="audio/midi",
            headers={"Content-Disposition": 'attachment; filename="result.mid"'},
        )

    @app.post("/api/gpu/release")
    async def release_gpu() -> dict[str, bool]:
        async with operation_lock:
            return {"released": await asyncio.to_thread(model_manager.release)}

    return app


app = create_app()
