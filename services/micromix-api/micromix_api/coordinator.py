from __future__ import annotations

import asyncio
from dataclasses import dataclass
from pathlib import Path
from typing import Protocol

from .models import JobKind, JobRecord, JobState, TERMINAL_STATES
from .store import JobStore


@dataclass(frozen=True, slots=True)
class UpstreamResult:
    state: str
    progress_detail: str | None = None
    data: bytes | None = None
    filename: str | None = None
    media_type: str | None = None
    error: str | None = None

    @classmethod
    def running(cls, detail: str | None = None) -> "UpstreamResult":
        return cls(state="running", progress_detail=detail)

    @classmethod
    def succeeded(
        cls,
        data: bytes,
        filename: str,
        media_type: str,
    ) -> "UpstreamResult":
        return cls(
            state="succeeded",
            data=data,
            filename=filename,
            media_type=media_type,
        )

    @classmethod
    def failed(cls, error: str) -> "UpstreamResult":
        return cls(state="failed", error=error)


class GPUAcquiring(Protocol):
    async def acquire(self, app: str, required_mib: int, wait_seconds: int) -> None: ...

    async def release(self, app: str) -> None: ...


class ACEGenerating(Protocol):
    async def submit(self, parameters: dict) -> str: ...

    async def poll(self, upstream_id: str) -> UpstreamResult: ...


class MIDITranscribing(Protocol):
    async def transcribe(
        self,
        path: Path,
        instruments: list[str],
        detect_tempo: bool,
    ) -> bytes: ...


class Coordinator:
    def __init__(
        self,
        store: JobStore,
        gpu: GPUAcquiring,
        ace: ACEGenerating,
        muscriptor: MIDITranscribing,
        *,
        poll_interval: float = 2.0,
    ):
        self.store = store
        self.gpu = gpu
        self.ace = ace
        self.muscriptor = muscriptor
        self.poll_interval = poll_interval

    async def run_job(self, job_id: str) -> None:
        job = await self.store.get_job(job_id)
        if job is None or job.state in TERMINAL_STATES:
            return
        try:
            if job.kind is JobKind.generation:
                await self._run_generation(job)
            else:
                await self._run_transcription(job)
        except Exception as exc:  # noqa: BLE001 - terminal boundary for durable jobs
            current = await self.store.get_job(job_id)
            if current is not None and current.state not in TERMINAL_STATES:
                await self.store.update_job(
                    job_id,
                    state=JobState.failed,
                    error=str(exc),
                    progress_detail=None,
                )

    async def _run_generation(self, job: JobRecord) -> None:
        await self.store.update_job(
            job.id,
            state=JobState.acquiring_gpu,
            progress_detail="waiting for RTX 3090",
        )
        await self.gpu.acquire("micromix-ace-step", 23_000, 60)
        try:
            await self._generate_after_acquire(job)
        finally:
            await self.gpu.release("micromix-ace-step")

    async def _generate_after_acquire(self, job: JobRecord) -> None:
        upstream_id = job.upstream_id
        if upstream_id is None:
            upstream_id = await self.ace.submit(job.parameters)
            await self.store.update_job(
                job.id,
                state=JobState.running,
                upstream_id=upstream_id,
                progress_detail="ACE-Step generation",
            )
        else:
            await self.store.update_job(
                job.id,
                state=JobState.running,
                progress_detail="resuming ACE-Step job",
            )

        while True:
            result = await self.ace.poll(upstream_id)
            if result.state == "running":
                await self.store.update_job(
                    job.id,
                    state=JobState.running,
                    progress_detail=result.progress_detail or "ACE-Step generation",
                )
                if self.poll_interval:
                    await asyncio.sleep(self.poll_interval)
                continue
            if result.state == "failed":
                await self.store.update_job(
                    job.id,
                    state=JobState.failed,
                    error=result.error or "ACE-Step generation failed",
                    progress_detail=None,
                )
                return
            if result.state != "succeeded" or result.data is None:
                raise RuntimeError(f"unexpected ACE-Step state: {result.state}")

            current = await self.store.get_job(job.id)
            if current is not None and current.cancel_requested:
                await self.store.update_job(
                    job.id,
                    state=JobState.cancelled,
                    progress_detail=None,
                )
                return

            filename = Path(result.filename or f"{job.id}.wav").name
            output = self._write_output(job.id, filename, result.data)
            await self.store.register_asset(
                job.id,
                output,
                result.media_type or "audio/wav",
                filename,
            )
            await self.store.update_job(
                job.id,
                state=JobState.succeeded,
                progress=1.0,
                progress_detail=None,
            )
            return

    async def _run_transcription(self, job: JobRecord) -> None:
        parameters = job.parameters
        input_path = Path(job.internal_parameters["input_path"])
        await self.store.update_job(
            job.id,
            state=JobState.acquiring_gpu,
            progress_detail="waiting for RTX 3090",
        )
        await self.gpu.acquire("micromix-muscriptor", 4_000, 60)
        try:
            await self.store.update_job(
                job.id,
                state=JobState.running,
                progress_detail="transcribing MIDI",
            )
            data = await self.muscriptor.transcribe(
                input_path,
                list(parameters.get("instruments", [])),
                bool(parameters.get("detect_tempo", True)),
            )
            current = await self.store.get_job(job.id)
            if current is not None and current.cancel_requested:
                await self.store.update_job(job.id, state=JobState.cancelled, progress_detail=None)
                return
            filename = f"{Path(parameters['filename']).stem}.mid"
            output = self._write_output(job.id, filename, data)
            await self.store.register_asset(job.id, output, "audio/midi", filename)
            await self.store.update_job(
                job.id,
                state=JobState.succeeded,
                progress=1.0,
                progress_detail=None,
            )
        finally:
            await self.gpu.release("micromix-muscriptor")

    def _write_output(self, job_id: str, filename: str, data: bytes) -> Path:
        directory = self.store.asset_root / job_id
        directory.mkdir(parents=True, exist_ok=True)
        output = directory / Path(filename).name
        output.write_bytes(data)
        return output


class Dispatcher:
    def __init__(self, coordinator: Coordinator):
        self.coordinator = coordinator
        self.queue: asyncio.Queue[str] = asyncio.Queue()
        self.task: asyncio.Task[None] | None = None

    def start(self) -> None:
        if self.task is None:
            self.task = asyncio.create_task(self._run())

    async def enqueue(self, job_id: str) -> None:
        await self.queue.put(job_id)

    async def join(self) -> None:
        await self.queue.join()

    async def close(self) -> None:
        if self.task is None:
            return
        self.task.cancel()
        try:
            await self.task
        except asyncio.CancelledError:
            pass
        self.task = None

    async def _run(self) -> None:
        while True:
            job_id = await self.queue.get()
            try:
                await self.coordinator.run_job(job_id)
            finally:
                self.queue.task_done()
