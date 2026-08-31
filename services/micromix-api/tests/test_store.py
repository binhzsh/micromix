from __future__ import annotations

import sqlite3
import asyncio
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

from micromix_api.models import AssetDirection, JobKind, JobState
from micromix_api.store import InputAssetBinding, JobStore, OutputAssetBinding


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
    asset = await store.register_output(job.id, output, "audio/wav", "render.wav")
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
async def test_asset_can_feed_two_jobs_and_each_job_can_have_multiple_outputs(
    store: JobStore,
):
    source_path = store.asset_root / "source.wav"
    source_path.write_bytes(b"RIFF-source")
    source = await store.create_asset(source_path, "audio/wav", "source.wav")
    first = await store.create_job(JobKind.generation, {"prompt": "first"})
    second = await store.create_job(JobKind.generation, {"prompt": "second"})

    await store.attach_asset(first.id, source.id, AssetDirection.input, "source")
    await store.attach_asset(second.id, source.id, AssetDirection.input, "reference")
    for position, name in enumerate(("take-1.wav", "take-2.wav")):
        path = store.asset_root / name
        path.write_bytes(f"RIFF-{position}".encode())
        await store.register_output(
            first.id,
            path,
            "audio/wav",
            name,
            name="variation",
            position=position,
        )

    persisted_first = await store.get_job(first.id)
    persisted_second = await store.get_job(second.id)
    assert [link.asset.id for link in persisted_first.inputs] == [source.id]
    assert [link.asset.filename for link in persisted_first.outputs] == [
        "take-1.wav",
        "take-2.wav",
    ]
    assert persisted_first.asset == persisted_first.outputs[0].asset
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
        await store.create_asset(outside, "audio/wav", outside.name)


@pytest.mark.asyncio
async def test_prune_removes_only_expired_terminal_assets(store: JobStore, tmp_path: Path):
    old = await store.create_job(JobKind.generation, {"prompt": "old"})
    recent = await store.create_job(JobKind.generation, {"prompt": "recent"})
    old_file = store.asset_root / "old.wav"
    recent_file = store.asset_root / "recent.wav"
    old_file.write_bytes(b"old")
    recent_file.write_bytes(b"recent")
    await store.register_output(old.id, old_file, "audio/wav", old_file.name)
    await store.register_output(recent.id, recent_file, "audio/wav", recent_file.name)
    await store.update_job(old.id, state=JobState.succeeded)
    await store.update_job(recent.id, state=JobState.succeeded)
    old_time = datetime.now(timezone.utc) - timedelta(days=8)
    await store.update_job(old.id, updated_at=old_time)

    count = await store.prune_assets(older_than=datetime.now(timezone.utc) - timedelta(days=7))

    assert count == 1
    assert not old_file.exists()
    assert recent_file.exists()
    assert (await store.get_job(old.id)).asset is None


@pytest.mark.asyncio
async def test_open_migrates_legacy_single_asset_schema(tmp_path: Path):
    database_path = tmp_path / "gateway.db"
    asset_root = tmp_path / "assets"
    asset_root.mkdir()
    output = asset_root / "legacy.wav"
    output.write_bytes(b"RIFF-legacy")
    now = datetime.now(timezone.utc).isoformat()
    connection = sqlite3.connect(database_path)
    connection.executescript(
        """
        CREATE TABLE jobs (
            id TEXT PRIMARY KEY,
            kind TEXT NOT NULL,
            state TEXT NOT NULL,
            parameters_json TEXT NOT NULL,
            progress REAL,
            progress_detail TEXT,
            upstream_id TEXT,
            cancel_requested INTEGER NOT NULL DEFAULT 0,
            error TEXT,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
        );
        CREATE TABLE assets (
            id TEXT PRIMARY KEY,
            job_id TEXT NOT NULL UNIQUE REFERENCES jobs(id) ON DELETE CASCADE,
            relative_path TEXT NOT NULL UNIQUE,
            filename TEXT NOT NULL,
            media_type TEXT NOT NULL,
            size_bytes INTEGER NOT NULL,
            sha256 TEXT NOT NULL,
            created_at TEXT NOT NULL
        );
        """
    )
    connection.execute(
        """
        INSERT INTO jobs (
            id, kind, state, parameters_json, progress, cancel_requested,
            created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """,
        ("legacy-job", "generation", "succeeded", '{"prompt":"legacy"}', 1.0, 0, now, now),
    )
    connection.execute(
        """
        INSERT INTO assets (
            id, job_id, relative_path, filename, media_type, size_bytes,
            sha256, created_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (
            "legacy-asset",
            "legacy-job",
            "legacy.wav",
            "legacy.wav",
            "audio/wav",
            output.stat().st_size,
            "0" * 64,
            now,
        ),
    )
    connection.commit()
    connection.close()

    store = JobStore(database_path, asset_root)
    await store.open()
    migrated = await store.get_job("legacy-job")
    asset_value = await store.get_asset("legacy-asset")
    version = await (await store.db.execute("PRAGMA user_version")).fetchone()
    await store.close()

    assert migrated is not None
    assert [(link.name, link.position) for link in migrated.outputs] == [("result", 0)]
    assert migrated.asset == migrated.outputs[0].asset
    assert asset_value is not None and asset_value[1].read_bytes() == b"RIFF-legacy"
    assert version[0] == 1


@pytest.mark.asyncio
async def test_prune_retains_shared_active_input_and_removes_old_orphan(
    store: JobStore,
):
    cutoff = datetime.now(timezone.utc) - timedelta(days=7)
    old_time = cutoff - timedelta(days=1)
    shared_path = store.asset_root / "shared.wav"
    shared_path.write_bytes(b"RIFF-shared")
    shared = await store.create_asset(shared_path, "audio/wav", shared_path.name)
    orphan_path = store.asset_root / "orphan.wav"
    orphan_path.write_bytes(b"RIFF-orphan")
    orphan = await store.create_asset(orphan_path, "audio/wav", orphan_path.name)
    old_job = await store.create_job(JobKind.generation, {"prompt": "old"})
    active_job = await store.create_job(JobKind.generation, {"prompt": "active"})
    await store.attach_asset(
        old_job.id,
        shared.id,
        AssetDirection.input,
        "source",
    )
    await store.attach_asset(
        active_job.id,
        shared.id,
        AssetDirection.input,
        "source",
    )
    await store.update_job(
        old_job.id,
        state=JobState.succeeded,
        updated_at=old_time,
    )
    await store.db.execute(
        "UPDATE assets SET created_at = ? WHERE id IN (?, ?)",
        (old_time.isoformat(), shared.id, orphan.id),
    )
    await store.db.commit()

    count = await store.prune_assets(older_than=cutoff)

    assert count == 1
    assert shared_path.exists()
    assert not orphan_path.exists()
    assert await store.get_asset(orphan.id) is None
    assert await store.get_asset(shared.id) is not None


@pytest.mark.asyncio
async def test_create_job_attaches_inputs_in_the_same_transaction(store: JobStore):
    source_path = store.asset_root / "source.wav"
    source_path.write_bytes(b"RIFF-source")
    source = await store.create_asset(source_path, "audio/wav", "source.wav")

    job = await store.create_job(
        JobKind.generation,
        {"operation": "remix", "_upstream_recovery_count": 0},
        inputs=[InputAssetBinding(source.id, "source")],
    )

    assert [(link.name, link.asset.id) for link in job.inputs] == [
        ("source", source.id)
    ]
    assert job.parameters == {"operation": "remix"}
    assert job.internal_parameters == {"upstream_recovery_count": 0}


@pytest.mark.asyncio
async def test_create_job_rolls_back_when_an_input_is_missing(store: JobStore):
    before = await store.list_jobs()

    with pytest.raises(KeyError, match="missing"):
        await store.create_job(
            JobKind.generation,
            {"operation": "remix"},
            inputs=[InputAssetBinding("missing", "source")],
        )

    assert await store.list_jobs() == before


@pytest.mark.asyncio
async def test_update_internal_parameters_stays_hidden(store: JobStore):
    job = await store.create_job(
        JobKind.generation,
        {"operation": "reference", "_upstream_recovery_count": 0},
    )

    updated = await store.update_internal_parameters(
        job.id,
        {"upstream_recovery_count": 1},
    )

    assert updated.parameters == {"operation": "reference"}
    assert updated.internal_parameters == {"upstream_recovery_count": 1}


@pytest.mark.asyncio
async def test_register_outputs_is_atomic_and_ordered(store: JobStore):
    job = await store.create_job(JobKind.generation, {"operation": "remix"})
    first = store.asset_root / "first.wav"
    second = store.asset_root / "second.wav"
    first.write_bytes(b"RIFF-first")
    second.write_bytes(b"RIFF-second")

    assets = await store.register_outputs(
        job.id,
        [
            OutputAssetBinding(first, "audio/wav", "first.wav", position=0),
            OutputAssetBinding(second, "audio/wav", "second.wav", position=1),
        ],
    )

    persisted = await store.get_job(job.id)
    assert [asset.filename for asset in assets] == ["first.wav", "second.wav"]
    assert [(link.name, link.position) for link in persisted.outputs] == [
        ("result", 0),
        ("result", 1),
    ]
    assert persisted.asset == persisted.outputs[0].asset


@pytest.mark.asyncio
async def test_register_outputs_rolls_back_when_any_output_is_invalid(
    store: JobStore,
    tmp_path: Path,
):
    job = await store.create_job(JobKind.generation, {"operation": "remix"})
    valid = store.asset_root / "valid.wav"
    invalid = tmp_path / "outside.wav"
    valid.write_bytes(b"RIFF-valid")
    invalid.write_bytes(b"RIFF-outside")

    with pytest.raises(ValueError, match="asset path"):
        await store.register_outputs(
            job.id,
            [
                OutputAssetBinding(valid, "audio/wav", "valid.wav", position=0),
                OutputAssetBinding(invalid, "audio/wav", "outside.wav", position=1),
            ],
        )

    persisted = await store.get_job(job.id)
    assert persisted.outputs == []
    count = await (
        await store.db.execute("SELECT COUNT(*) FROM assets")
    ).fetchone()
    assert count[0] == 0


@pytest.mark.asyncio
async def test_concurrent_job_creation_is_serialized(store: JobStore):
    jobs = await asyncio.gather(
        *[
            store.create_job(
                JobKind.generation,
                {"prompt": f"job-{index}"},
            )
            for index in range(8)
        ]
    )

    persisted = await store.list_jobs()
    assert {job.id for job in jobs} == {job.id for job in persisted}


@pytest.mark.asyncio
async def test_concurrent_asset_and_job_writes_do_not_cross_transactions(
    store: JobStore,
):
    paths = []
    for index in range(4):
        path = store.asset_root / f"input-{index}.wav"
        path.write_bytes(f"RIFF-{index}".encode())
        paths.append(path)

    results = await asyncio.gather(
        *[
            store.create_asset(path, "audio/wav", path.name)
            for path in paths
        ],
        *[
            store.create_job(
                JobKind.generation,
                {"prompt": f"job-{index}"},
            )
            for index in range(4)
        ],
    )

    assert len(results) == 8
    count = await (
        await store.db.execute("SELECT COUNT(*) FROM assets")
    ).fetchone()
    assert count[0] == 4
    assert len(await store.list_jobs()) == 4


@pytest.mark.asyncio
async def test_complete_with_outputs_rolls_back_links_when_state_update_fails(
    store: JobStore,
):
    job = await store.create_job(JobKind.generation, {"prompt": "song"})
    output = store.asset_root / "result.wav"
    output.write_bytes(b"RIFF-result")
    await store.db.execute(
        """
        CREATE TRIGGER reject_success
        BEFORE UPDATE OF state ON jobs
        WHEN NEW.state = 'succeeded'
        BEGIN
            SELECT RAISE(ABORT, 'reject success');
        END
        """
    )
    await store.db.commit()

    with pytest.raises(Exception, match="reject success"):
        await store.register_outputs(
            job.id,
            [OutputAssetBinding(output, "audio/wav", "result.wav")],
            complete_job=True,
        )

    persisted = await store.get_job(job.id)
    assert persisted.state is JobState.queued
    assert persisted.outputs == []
    count = await (
        await store.db.execute("SELECT COUNT(*) FROM assets")
    ).fetchone()
    assert count[0] == 0
