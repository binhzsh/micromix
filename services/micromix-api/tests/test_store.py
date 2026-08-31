from __future__ import annotations

from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

from micromix_api.models import AssetDirection, JobKind, JobState
from micromix_api.store import JobStore


@pytest.fixture
async def store(tmp_path: Path):
    value = JobStore(tmp_path / "gateway.db", tmp_path / "assets")
    await value.open()
    yield value
    await value.close()


def test_asset_direction_uses_stable_wire_values():
    assert AssetDirection.input.value == "input"
    assert AssetDirection.output.value == "output"


@pytest.mark.asyncio
async def test_job_lifecycle_persists_result_asset(store: JobStore, tmp_path: Path):
    job = await store.create_job(JobKind.generation, {"prompt": "warm jazz"})
    await store.update_job(job.id, state=JobState.running, upstream_id="ace-123")

    output = store.asset_root / "render.wav"
    output.write_bytes(b"RIFF-test-audio")
    asset = await store.register_asset(job.id, output, "audio/wav", "render.wav")
    await store.update_job(job.id, state=JobState.succeeded, progress=1.0)

    persisted = await store.get_job(job.id)
    assert persisted is not None
    assert persisted.state is JobState.succeeded
    assert persisted.upstream_id == "ace-123"
    assert persisted.asset is not None
    assert persisted.asset.id == asset.id
    assert persisted.asset.size_bytes == len(b"RIFF-test-audio")
    assert len(persisted.asset.sha256) == 64


@pytest.mark.asyncio
async def test_recovery_requeues_generation_and_interrupts_transcription(store: JobStore):
    queued = await store.create_job(JobKind.generation, {"prompt": "queued"})
    generation = await store.create_job(JobKind.generation, {"prompt": "running"})
    transcription = await store.create_job(JobKind.transcription, {"filename": "voice.wav"})
    await store.update_job(generation.id, state=JobState.running, upstream_id="ace-456")
    await store.update_job(transcription.id, state=JobState.running)

    recovered = await store.recover_jobs()

    assert set(recovered) == {queued.id, generation.id}
    assert (await store.get_job(queued.id)).state is JobState.queued
    assert (await store.get_job(generation.id)).state is JobState.queued
    interrupted = await store.get_job(transcription.id)
    assert interrupted.state is JobState.failed
    assert "interrupted" in interrupted.error.lower()


@pytest.mark.asyncio
async def test_asset_lookup_rejects_paths_outside_asset_root(store: JobStore, tmp_path: Path):
    job = await store.create_job(JobKind.generation, {"prompt": "safe"})
    outside = tmp_path.parent / "outside.wav"
    outside.write_bytes(b"outside")

    with pytest.raises(ValueError, match="asset root"):
        await store.register_asset(job.id, outside, "audio/wav", outside.name)


@pytest.mark.asyncio
async def test_prune_removes_only_expired_terminal_assets(store: JobStore, tmp_path: Path):
    old = await store.create_job(JobKind.generation, {"prompt": "old"})
    recent = await store.create_job(JobKind.generation, {"prompt": "recent"})
    old_file = store.asset_root / "old.wav"
    recent_file = store.asset_root / "recent.wav"
    old_file.write_bytes(b"old")
    recent_file.write_bytes(b"recent")
    await store.register_asset(old.id, old_file, "audio/wav", old_file.name)
    await store.register_asset(recent.id, recent_file, "audio/wav", recent_file.name)
    await store.update_job(old.id, state=JobState.succeeded)
    await store.update_job(recent.id, state=JobState.succeeded)
    old_time = datetime.now(timezone.utc) - timedelta(days=8)
    await store.update_job(old.id, updated_at=old_time)

    count = await store.prune_assets(older_than=datetime.now(timezone.utc) - timedelta(days=7))

    assert count == 1
    assert not old_file.exists()
    assert recent_file.exists()
    assert (await store.get_job(old.id)).asset is None
