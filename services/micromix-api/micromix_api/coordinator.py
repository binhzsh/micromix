from __future__ import annotations

import asyncio
from dataclasses import dataclass
from pathlib import Path
from typing import Protocol

from .models import JobKind, JobRecord, JobState, TERMINAL_STATES
from .store import JobStore, OutputAssetBinding


@dataclass(frozen=True, slots=True)
class UpstreamOutput:
    data: bytes
    filename: str
    media_type: str


@dataclass(frozen=True, slots=True)
class UpstreamResult:
    state: str
    progress_detail: str | None = None
    outputs: tuple[UpstreamOutput, ...] = ()
    error: str | None = None

    @property
    def data(self) -> bytes | None:
        return self.outputs[0].data if self.outputs else None

    @property
    def filename(self) -> str | None:
        return self.outputs[0].filename if self.outputs else None

    @property
    def media_type(self) -> str | None:
        return self.outputs[0].media_type if self.outputs else None

    @classmethod
    def running(cls, detail: str | None = None) -> "UpstreamResult":
        return cls(state="running", progress_detail=detail)

    @classmethod
    def succeeded(
        cls,
        data: bytes | tuple[UpstreamOutput, ...],
        filename: str | None = None,
        media_type: str | None = None,
    ) -> "UpstreamResult":
        if isinstance(data, tuple):
            outputs = data
        else:
            if filename is None or media_type is None:
                raise ValueError("filename and media type are required")
            outputs = (UpstreamOutput(data, filename, media_type),)
        return cls(state="succeeded", outputs=outputs)

    @classmethod
    def failed(cls, error: str) -> "UpstreamResult":
        return cls(state="failed", error=error)

    @classmethod
    def missing(cls) -> "UpstreamResult":
        return cls(state="missing")


class GPUAcquiring(Protocol):
    async def acquire(self, app: str, required_mib: int, wait_seconds: int) -> None: ...

    async def release(self, app: str) -> None: ...


class ACEGenerating(Protocol):
    async def submit(
        self,
        parameters: dict,
        *,
        reference_audio: Path | None = None,
        source_audio: Path | None = None,
    ) -> str: ...

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

    async def _resolve_generation_audio(
        self,
        job: JobRecord,
    ) -> tuple[Path | None, Path | None]:
        operation = job.parameters.get("operation", "text")
        if operation == "text":
            return None, None
        input_name = "reference" if operation == "reference" else "source"
        link = next(
            (candidate for candidate in job.inputs if candidate.name == input_name),
            None,
        )
        if link is None:
            raise RuntimeError(f"{input_name} input is unavailable")
        value = await self.store.get_asset(link.asset.id)
        if value is None or not value[1].is_file():
            raise RuntimeError(f"{input_name} input file is unavailable")
        path = value[1]
        return (path, None) if input_name == "reference" else (None, path)

    async def _generate_after_acquire(self, job: JobRecord) -> None:
        reference_audio, source_audio = await self._resolve_generation_audio(job)

        async def submit() -> str:
            return await self.ace.submit(
                job.parameters,
                reference_audio=reference_audio,
                source_audio=source_audio,
            )

        upstream_id = job.upstream_id
        if upstream_id is None:
            upstream_id = await submit()
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
            current = await self.store.get_job(job.id)
            if current is not None and current.cancel_requested:
                await self.store.update_job(
                    job.id,
                    state=JobState.cancelled,
                    progress_detail=None,
                )
                return

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
            if result.state == "missing":
                current = await self.store.get_job(job.id)
                recovery_count = (
                    int(current.internal_parameters.get("upstream_recovery_count", 0))
                    if current is not None
                    else 0
                )
                if recovery_count >= 1:
                    await self.store.update_job(
                        job.id,
                        state=JobState.failed,
                        error="ACE-Step task disappeared after recovery",
                        progress_detail=None,
                    )
                    return
                await self.store.update_internal_parameters(
                    job.id,
                    {"upstream_recovery_count": 1},
                )
                upstream_id = await submit()
                await self.store.update_job(
                    job.id,
                    state=JobState.running,
                    upstream_id=upstream_id,
                    progress_detail="recovering ACE-Step generation",
                )
                continue
            if result.state != "succeeded":
                raise RuntimeError(f"unexpected ACE-Step state: {result.state}")

            expected_count = int(job.parameters.get("variation_count", 1))
            if len(result.outputs) != expected_count:
                raise RuntimeError(
                    f"expected {expected_count} ACE-Step outputs, "
                    f"received {len(result.outputs)}"
                )

            directory = self.store.asset_root / job.id
            self._remove_output_directory(directory)
            bindings: list[OutputAssetBinding] = []
            try:
                for position, upstream_output in enumerate(result.outputs):
                    filename = (
                        "result.wav"
                        if expected_count == 1
                        else f"result-{position + 1}.wav"
                    )
                    output = self._write_output(
                        job.id,
                        filename,
                        upstream_output.data,
                    )
                    bindings.append(
                        OutputAssetBinding(
                            path=output,
                            media_type=upstream_output.media_type or "audio/wav",
                            filename=filename,
                            name="result",
                            position=position,
                        )
                    )
                await self.store.register_outputs(
                    job.id,
                    bindings,
                    complete_job=True,
                )
            except Exception:
                self._remove_output_directory(directory)
                raise
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
            await self.store.register_output(
                job.id,
                output,
                "audio/midi",
                filename,
                name="midi",
                position=0,
            )
            await self.store.update_job(
                job.id,
                state=JobState.succeeded,
                progress=1.0,
                progress_detail=None,
            )
        finally:
            await self.gpu.release("micromix-muscriptor")

    def _remove_output_directory(self, directory: Path) -> None:
        if not directory.exists():
            return
        resolved = directory.resolve()
        if not resolved.is_relative_to(self.store.asset_root.resolve()):
            raise ValueError("output directory must remain beneath asset root")
        for child in resolved.iterdir():
            if child.is_file():
                child.unlink()
        resolved.rmdir()

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
