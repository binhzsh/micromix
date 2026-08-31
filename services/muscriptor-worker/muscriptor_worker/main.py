from __future__ import annotations

import asyncio
import gc
import io
import os
import signal
import subprocess
import tempfile
import threading
import wave
from collections.abc import Callable
from pathlib import Path
from typing import Literal, Protocol

from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from fastapi.responses import Response


INSTRUMENTS = (
    "acoustic_bass",
    "acoustic_guitar",
    "acoustic_piano",
    "baritone_sax",
    "bassoon",
    "brass_section",
    "cello",
    "chromatic_percussion",
    "clarinet",
    "clean_electric_guitar",
    "contrabass",
    "distorted_electric_guitar",
    "drums",
    "electric_bass",
    "electric_piano",
    "english_horn",
    "flutes",
    "french_horn",
    "oboe",
    "orchestra_hit",
    "orchestral_harp",
    "organ",
    "soprano_and_alto_sax",
    "string_ensemble",
    "synth_lead",
    "synth_pad",
    "synth_strings",
    "tenor_sax",
    "timpani",
    "trombone",
    "trumpet",
    "tuba",
    "viola",
    "violin",
    "voice",
)


TempoDetection = bool | Literal["best-effort"]


class TranscriptionEngine(Protocol):
    def transcribe(
        self,
        data: bytes,
        instruments: list[str],
        detect_tempo: TempoDetection,
    ) -> bytes: ...

    def release(self) -> None: ...


def transcode_with_ffmpeg(data: bytes) -> bytes:
    with tempfile.TemporaryDirectory(prefix="micromix-audio-") as directory:
        input_path = Path(directory) / "input.audio"
        output_path = Path(directory) / "decoded.wav"
        input_path.write_bytes(data)
        try:
            subprocess.run(
                [
                    "ffmpeg", "-v", "error", "-y", "-i", str(input_path),
                    "-acodec", "pcm_s16le", str(output_path),
                ],
                check=True,
                capture_output=True,
            )
        except (FileNotFoundError, subprocess.CalledProcessError) as exc:
            detail = getattr(exc, "stderr", b"")
            message = detail.decode("utf-8", errors="replace").strip()
            raise ValueError(f"could not decode audio with ffmpeg: {message or exc}") from exc
        return output_path.read_bytes()


def decode_audio(data, *, wav_reader, other_reader, transcode=transcode_with_ffmpeg):
    try:
        return wav_reader(io.BytesIO(data))
    except (wave.Error, EOFError):
        pass
    try:
        return other_reader(io.BytesIO(data))
    except Exception:
        try:
            return wav_reader(io.BytesIO(transcode(data)))
        except Exception as exc:
            if isinstance(exc, ValueError):
                raise
            raise ValueError(f"could not decode audio: {exc}") from exc


class MuScriptorEngine:
    def __init__(self) -> None:
        from muscriptor.main import _load_model

        model_path = os.getenv("MUSCRIPTOR_MODEL", "medium")
        device = os.getenv("MUSCRIPTOR_DEVICE", "cuda")
        dtype = os.getenv("MUSCRIPTOR_DTYPE")
        self.model = _load_model(model_path, device, dtype)

    def transcribe(
        self,
        data: bytes,
        instruments: list[str],
        detect_tempo: TempoDetection,
    ) -> bytes:
        from muscriptor.events import NoteStartEvent, ProgressEvent
        from muscriptor.tokenizer.mt3 import MT3_FULL_PLUS_GROUP_NAMES
        from muscriptor.utils.audio import _read_non_wav_file, _read_wav_file

        wav_data, sample_rate = decode_audio(
            data, wav_reader=_read_wav_file, other_reader=_read_non_wav_file
        )

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
    # MuScriptor 0.3.0's public MT3 vocabulary. Importing its tokenizer also
    # imports torch and creates a CUDA context, so capability discovery must
    # use this version-pinned copy while the worker is cold.
    return list(INSTRUMENTS)


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


def schedule_process_restart() -> None:
    timer = threading.Timer(0.1, os.kill, args=(os.getpid(), signal.SIGTERM))
    timer.daemon = True
    timer.start()


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
        detect_tempo: TempoDetection = Form("best-effort"),
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
            released = await asyncio.to_thread(model_manager.release)
        if released and os.getenv("MUSCRIPTOR_RESTART_AFTER_RELEASE") == "1":
            schedule_process_restart()
        return {"released": released}

    return app


app = create_app()
