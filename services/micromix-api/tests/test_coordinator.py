from __future__ import annotations

from pathlib import Path

import pytest

from micromix_api.coordinator import (
    Coordinator,
    Dispatcher,
    UpstreamOutput,
    UpstreamResult,
)
from micromix_api.models import JobKind, JobState
from micromix_api.store import InputAssetBinding, JobStore


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
        self.submissions: list[tuple[dict, Path | None, Path | None]] = []
        self.polls: list[str] = []

    async def submit(
        self,
        parameters: dict,
        *,
        reference_audio: Path | None = None,
        source_audio: Path | None = None,
    ) -> str:
        self.submissions.append((parameters, reference_audio, source_audio))
        return f"ace-task-{len(self.submissions)}"

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
    assert completed.outputs[0].name == "result"
    assert completed.asset == completed.outputs[0].asset
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
        {
            "prompt": "cancel",
            "preset": "turbo",
            "duration_seconds": 10,
            "variation_count": 2,
            "seeds": [1, 2],
        },
    )
    await store.update_job(
        job.id,
        state=JobState.queued,
        upstream_id="cancel-task",
        cancel_requested=True,
    )
    ace = FakeACE(
        [
            UpstreamResult.succeeded(
                (
                    UpstreamOutput(b"RIFF-a", "a.wav", "audio/wav"),
                    UpstreamOutput(b"RIFF-b", "b.wav", "audio/wav"),
                )
            )
        ]
    )
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
    assert completed.outputs[0].name == "midi"
    assert completed.asset == completed.outputs[0].asset
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


async def create_source_job(
    store: JobStore,
    *,
    operation: str = "remix",
    variation_count: int = 1,
    recovery_count: int = 0,
):
    source = store.asset_root / "imports" / "source.wav"
    source.parent.mkdir(parents=True, exist_ok=True)
    source.write_bytes(b"RIFF-source")
    asset = await store.create_asset(source, "audio/wav", "source.wav")
    input_name = "reference" if operation == "reference" else "source"
    job = await store.create_job(
        JobKind.generation,
        {
            "operation": operation,
            "prompt": "new arrangement",
            "preset": "quality",
            "variation_count": variation_count,
            "seeds": list(range(41, 41 + variation_count)),
            "_upstream_recovery_count": recovery_count,
        },
        inputs=[InputAssetBinding(asset.id, input_name)],
    )
    return job, source


@pytest.mark.asyncio
async def test_source_job_submits_named_input_path(store: JobStore):
    job, source = await create_source_job(store)
    ace = FakeACE(
        [UpstreamResult.succeeded(b"RIFF-result", "result.wav", "audio/wav")]
    )
    coordinator = Coordinator(store, FakeGPU(), ace, FakeMuScriptor(), poll_interval=0)

    await coordinator.run_job(job.id)

    assert ace.submissions == [((await store.get_job(job.id)).parameters, None, source)]
    assert (await store.get_job(job.id)).state is JobState.succeeded


@pytest.mark.asyncio
async def test_generation_registers_ordered_output_batch(store: JobStore):
    job = await store.create_job(
        JobKind.generation,
        {
            "operation": "text",
            "prompt": "two versions",
            "variation_count": 2,
            "seeds": [7, 8],
        },
    )
    ace = FakeACE(
        [
            UpstreamResult.succeeded(
                (
                    UpstreamOutput(b"RIFF-first", "upstream-a.wav", "audio/wav"),
                    UpstreamOutput(b"RIFF-second", "upstream-b.wav", "audio/wav"),
                )
            )
        ]
    )
    coordinator = Coordinator(store, FakeGPU(), ace, FakeMuScriptor(), poll_interval=0)

    await coordinator.run_job(job.id)

    completed = await store.get_job(job.id)
    assert completed.state is JobState.succeeded
    assert [
        (link.asset.filename, link.position)
        for link in completed.outputs
    ] == [("result-1.wav", 0), ("result-2.wav", 1)]
    assert [
        (store.asset_root / link.asset.relative_path).read_bytes()
        for link in completed.outputs
    ] == [b"RIFF-first", b"RIFF-second"]
    assert completed.asset == completed.outputs[0].asset


@pytest.mark.asyncio
async def test_missing_upstream_resubmits_once_with_durable_input(store: JobStore):
    job, source = await create_source_job(store)
    await store.update_job(
        job.id,
        state=JobState.queued,
        upstream_id="lost-task",
    )
    ace = FakeACE(
        [
            UpstreamResult.missing(),
            UpstreamResult.succeeded(b"RIFF-recovered", "result.wav", "audio/wav"),
        ]
    )
    coordinator = Coordinator(store, FakeGPU(), ace, FakeMuScriptor(), poll_interval=0)

    await coordinator.run_job(job.id)

    completed = await store.get_job(job.id)
    assert completed.state is JobState.succeeded
    assert completed.internal_parameters["upstream_recovery_count"] == 1
    assert ace.submissions == [(completed.parameters, None, source)]
    assert ace.polls == ["lost-task", "ace-task-1"]


@pytest.mark.asyncio
async def test_missing_upstream_after_recovery_fails_without_resubmit(store: JobStore):
    job, _ = await create_source_job(store, recovery_count=1)
    await store.update_job(
        job.id,
        state=JobState.queued,
        upstream_id="replacement-task",
    )
    ace = FakeACE([UpstreamResult.missing()])
    coordinator = Coordinator(store, FakeGPU(), ace, FakeMuScriptor(), poll_interval=0)

    await coordinator.run_job(job.id)

    failed = await store.get_job(job.id)
    assert failed.state is JobState.failed
    assert failed.error == "ACE-Step task disappeared after recovery"
    assert ace.submissions == []


@pytest.mark.asyncio
async def test_output_count_mismatch_leaves_no_partial_outputs(store: JobStore):
    job = await store.create_job(
        JobKind.generation,
        {
            "operation": "text",
            "prompt": "two versions",
            "variation_count": 2,
            "seeds": [7, 8],
        },
    )
    ace = FakeACE(
        [UpstreamResult.succeeded(b"RIFF-only", "only.wav", "audio/wav")]
    )
    coordinator = Coordinator(store, FakeGPU(), ace, FakeMuScriptor(), poll_interval=0)

    await coordinator.run_job(job.id)

    failed = await store.get_job(job.id)
    assert failed.state is JobState.failed
    assert "expected 2 ACE-Step outputs, received 1" in failed.error
    assert failed.outputs == []
    assert not (store.asset_root / job.id).exists()


@pytest.mark.asyncio
async def test_batch_registration_failure_removes_staged_files(
    store: JobStore,
    monkeypatch: pytest.MonkeyPatch,
):
    job = await store.create_job(
        JobKind.generation,
        {
            "operation": "text",
            "prompt": "two versions",
            "variation_count": 2,
            "seeds": [7, 8],
        },
    )
    ace = FakeACE(
        [
            UpstreamResult.succeeded(
                (
                    UpstreamOutput(b"RIFF-first", "a.wav", "audio/wav"),
                    UpstreamOutput(b"RIFF-second", "b.wav", "audio/wav"),
                )
            )
        ]
    )

    async def reject_outputs(*args, **kwargs):
        raise RuntimeError("database unavailable")

    monkeypatch.setattr(store, "register_outputs", reject_outputs)
    coordinator = Coordinator(store, FakeGPU(), ace, FakeMuScriptor(), poll_interval=0)

    await coordinator.run_job(job.id)

    failed = await store.get_job(job.id)
    assert failed.state is JobState.failed
    assert failed.outputs == []
    assert not (store.asset_root / job.id).exists()


@pytest.mark.asyncio
async def test_cancel_requested_prevents_missing_task_resubmission(store: JobStore):
    job, _ = await create_source_job(store)
    await store.update_job(
        job.id,
        state=JobState.queued,
        upstream_id="lost-task",
        cancel_requested=True,
    )
    ace = FakeACE([UpstreamResult.missing()])
    coordinator = Coordinator(
        store,
        FakeGPU(),
        ace,
        FakeMuScriptor(),
        poll_interval=0,
    )

    await coordinator.run_job(job.id)

    cancelled = await store.get_job(job.id)
    assert cancelled.state is JobState.cancelled
    assert cancelled.outputs == []
    assert ace.submissions == []
    assert ace.polls == []
    assert not (store.asset_root / job.id).exists()
