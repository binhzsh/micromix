from __future__ import annotations

from pathlib import Path

import pytest

from micromix_api.coordinator import Coordinator, Dispatcher, UpstreamResult
from micromix_api.models import JobKind, JobState
from micromix_api.store import JobStore


class FakeGPU:
    def __init__(self):
        self.requests: list[tuple[str, int, int]] = []
        self.releases: list[str] = []

    async def acquire(self, app: str, required_mib: int, wait_seconds: int) -> None:
        self.requests.append((app, required_mib, wait_seconds))

    async def release(self, app: str) -> None:
        self.releases.append(app)


class FakeACE:
    def __init__(self, results: list[UpstreamResult]):
        self.results = results
        self.submissions: list[dict] = []
        self.polls: list[str] = []

    async def submit(self, parameters: dict) -> str:
        self.submissions.append(parameters)
        return "ace-task-1"

    async def poll(self, upstream_id: str) -> UpstreamResult:
        self.polls.append(upstream_id)
        return self.results.pop(0)


class FakeMuScriptor:
    def __init__(self, output: bytes = b"MThd-midi"):
        self.output = output
        self.calls: list[tuple[Path, list[str], bool]] = []

    async def transcribe(
        self,
        path: Path,
        instruments: list[str],
        detect_tempo: bool,
    ) -> bytes:
        self.calls.append((path, instruments, detect_tempo))
        return self.output


@pytest.fixture
async def store(tmp_path: Path):
    value = JobStore(tmp_path / "gateway.db", tmp_path / "assets")
    await value.open()
    yield value
    await value.close()


@pytest.mark.asyncio
async def test_generation_acquires_gpu_polls_and_registers_wav(store: JobStore):
    job = await store.create_job(
        JobKind.generation,
        {"prompt": "jazz", "preset": "turbo", "duration_seconds": 10},
    )
    gpu = FakeGPU()
    ace = FakeACE(
        [
            UpstreamResult.running("diffusion"),
            UpstreamResult.succeeded(b"RIFF-generated", "result.wav", "audio/wav"),
        ]
    )
    coordinator = Coordinator(store, gpu, ace, FakeMuScriptor(), poll_interval=0)

    await coordinator.run_job(job.id)

    completed = await store.get_job(job.id)
    assert completed.state is JobState.succeeded
    assert completed.progress == 1.0
    assert completed.asset is not None
    assert (store.asset_root / completed.asset.relative_path).read_bytes() == b"RIFF-generated"
    assert gpu.requests == [("micromix-ace-step", 23000, 60)]
    assert gpu.releases == ["micromix-ace-step"]
    assert len(ace.submissions) == 1
    assert ace.polls == ["ace-task-1", "ace-task-1"]


@pytest.mark.asyncio
async def test_recovered_generation_with_upstream_id_does_not_resubmit(store: JobStore):
    job = await store.create_job(
        JobKind.generation,
        {"prompt": "resume", "preset": "quality", "duration_seconds": 10},
    )
    await store.update_job(job.id, state=JobState.queued, upstream_id="existing-task")
    ace = FakeACE([UpstreamResult.succeeded(b"RIFF-resumed", "resume.wav", "audio/wav")])
    coordinator = Coordinator(store, FakeGPU(), ace, FakeMuScriptor(), poll_interval=0)

    await coordinator.run_job(job.id)

    assert ace.submissions == []
    assert ace.polls == ["existing-task"]
    assert (await store.get_job(job.id)).state is JobState.succeeded


@pytest.mark.asyncio
async def test_cancel_requested_discards_completed_generation(store: JobStore):
    job = await store.create_job(
        JobKind.generation,
        {"prompt": "cancel", "preset": "turbo", "duration_seconds": 10},
    )
    await store.update_job(
        job.id,
        state=JobState.queued,
        upstream_id="cancel-task",
        cancel_requested=True,
    )
    ace = FakeACE([UpstreamResult.succeeded(b"RIFF-discard", "discard.wav", "audio/wav")])
    coordinator = Coordinator(store, FakeGPU(), ace, FakeMuScriptor(), poll_interval=0)

    await coordinator.run_job(job.id)

    cancelled = await store.get_job(job.id)
    assert cancelled.state is JobState.cancelled
    assert cancelled.asset is None
    assert list(store.asset_root.rglob("*.wav")) == []


@pytest.mark.asyncio
async def test_transcription_acquires_gpu_and_registers_midi(store: JobStore, tmp_path: Path):
    upload = tmp_path / "voice.wav"
    upload.write_bytes(b"RIFF-input")
    job = await store.create_job(
        JobKind.transcription,
        {
            "filename": "voice.wav",
            "_input_path": str(upload),
            "instruments": ["vocals"],
            "detect_tempo": True,
        },
    )
    gpu = FakeGPU()
    muscriptor = FakeMuScriptor()
    coordinator = Coordinator(
        store,
        gpu,
        FakeACE([]),
        muscriptor,
        poll_interval=0,
    )

    await coordinator.run_job(job.id)

    completed = await store.get_job(job.id)
    assert completed.state is JobState.succeeded
    assert completed.asset.filename == "voice.mid"
    assert muscriptor.calls == [(upload, ["vocals"], True)]
    assert gpu.requests == [("micromix-muscriptor", 4000, 60)]
    assert gpu.releases == ["micromix-muscriptor"]


@pytest.mark.asyncio
async def test_upstream_failure_becomes_terminal_job_error(store: JobStore):
    job = await store.create_job(
        JobKind.generation,
        {"prompt": "fail", "preset": "turbo", "duration_seconds": 10},
    )
    ace = FakeACE([UpstreamResult.failed("model exploded")])
    coordinator = Coordinator(store, FakeGPU(), ace, FakeMuScriptor(), poll_interval=0)

    await coordinator.run_job(job.id)

    failed = await store.get_job(job.id)
    assert failed.state is JobState.failed
    assert failed.error == "model exploded"


@pytest.mark.asyncio
async def test_dispatcher_runs_enqueued_job_and_drains(store: JobStore):
    job = await store.create_job(
        JobKind.generation,
        {"prompt": "queued", "preset": "turbo", "duration_seconds": 10},
    )
    coordinator = Coordinator(
        store,
        FakeGPU(),
        FakeACE([UpstreamResult.succeeded(b"RIFF-done", "done.wav", "audio/wav")]),
        FakeMuScriptor(),
        poll_interval=0,
    )
    dispatcher = Dispatcher(coordinator)
    dispatcher.start()

    await dispatcher.enqueue(job.id)
    await dispatcher.join()
    await dispatcher.close()

    assert (await store.get_job(job.id)).state is JobState.succeeded
