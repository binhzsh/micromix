from __future__ import annotations

import asyncio
import hashlib
import json
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import aiosqlite

from .models import (
    AssetDirection,
    AssetRecord,
    JobAssetLink,
    JobKind,
    JobRecord,
    JobState,
    TERMINAL_STATES,
)


_SCHEMA = """
PRAGMA journal_mode=WAL;
PRAGMA foreign_keys=ON;

CREATE TABLE IF NOT EXISTS jobs (
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

CREATE TABLE IF NOT EXISTS assets (
    id TEXT PRIMARY KEY,
    relative_path TEXT NOT NULL UNIQUE,
    filename TEXT NOT NULL,
    media_type TEXT NOT NULL,
    size_bytes INTEGER NOT NULL,
    sha256 TEXT NOT NULL,
    created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS job_assets (
    job_id TEXT NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
    asset_id TEXT NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
    direction TEXT NOT NULL CHECK(direction IN ('input', 'output')),
    name TEXT NOT NULL,
    position INTEGER NOT NULL DEFAULT 0 CHECK(position >= 0),
    PRIMARY KEY (job_id, direction, name, position),
    UNIQUE (job_id, asset_id, direction)
);

CREATE INDEX IF NOT EXISTS jobs_state_created_idx ON jobs(state, created_at);
CREATE INDEX IF NOT EXISTS job_assets_asset_idx ON job_assets(asset_id);
PRAGMA user_version=1;
"""

_LEGACY_ASSET_MIGRATION = """
PRAGMA foreign_keys=OFF;
BEGIN IMMEDIATE;

ALTER TABLE assets RENAME TO assets_legacy;

CREATE TABLE assets (
    id TEXT PRIMARY KEY,
    relative_path TEXT NOT NULL UNIQUE,
    filename TEXT NOT NULL,
    media_type TEXT NOT NULL,
    size_bytes INTEGER NOT NULL,
    sha256 TEXT NOT NULL,
    created_at TEXT NOT NULL
);

CREATE TABLE job_assets (
    job_id TEXT NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
    asset_id TEXT NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
    direction TEXT NOT NULL CHECK(direction IN ('input', 'output')),
    name TEXT NOT NULL,
    position INTEGER NOT NULL DEFAULT 0 CHECK(position >= 0),
    PRIMARY KEY (job_id, direction, name, position),
    UNIQUE (job_id, asset_id, direction)
);

INSERT INTO assets (
    id, relative_path, filename, media_type, size_bytes, sha256, created_at
)
SELECT id, relative_path, filename, media_type, size_bytes, sha256, created_at
FROM assets_legacy;

INSERT INTO job_assets (job_id, asset_id, direction, name, position)
SELECT job_id, id, 'output', 'result', 0 FROM assets_legacy;

DROP TABLE assets_legacy;
CREATE INDEX IF NOT EXISTS jobs_state_created_idx ON jobs(state, created_at);
CREATE INDEX job_assets_asset_idx ON job_assets(asset_id);
PRAGMA user_version=1;
COMMIT;
PRAGMA foreign_keys=ON;
"""


def _now() -> datetime:
    return datetime.now(timezone.utc)


def _serialized_write(method):
    async def wrapped(self, *args, **kwargs):
        async with self._write_lock:
            return await method(self, *args, **kwargs)

    return wrapped


@dataclass(frozen=True, slots=True)
class InputAssetBinding:
    asset_id: str
    name: str
    position: int = 0


@dataclass(frozen=True, slots=True)
class OutputAssetBinding:
    path: Path
    media_type: str
    filename: str
    name: str = "result"
    position: int = 0


class JobCancellationRequested(RuntimeError):
    pass


class JobStore:
    def __init__(self, database_path: Path, asset_root: Path):
        self.database_path = database_path
        self.asset_root = asset_root
        self._db: aiosqlite.Connection | None = None
        self._write_lock = asyncio.Lock()

    async def open(self) -> None:
        self.database_path.parent.mkdir(parents=True, exist_ok=True)
        self.asset_root.mkdir(parents=True, exist_ok=True)
        self._db = await aiosqlite.connect(self.database_path)
        self._db.row_factory = aiosqlite.Row
        cursor = await self._db.execute("PRAGMA table_info(assets)")
        asset_columns = {row["name"] for row in await cursor.fetchall()}
        if "job_id" in asset_columns:
            await self._db.executescript(_LEGACY_ASSET_MIGRATION)
        else:
            await self._db.executescript(_SCHEMA)
        await self._db.commit()

    async def close(self) -> None:
        if self._db is not None:
            await self._db.close()
            self._db = None

    @property
    def db(self) -> aiosqlite.Connection:
        if self._db is None:
            raise RuntimeError("store is not open")
        return self._db

    @_serialized_write
    async def create_job(
        self,
        kind: JobKind,
        parameters: dict[str, Any],
        *,
        inputs: list[InputAssetBinding] | tuple[InputAssetBinding, ...] = (),
    ) -> JobRecord:
        resolved_inputs = [
            InputAssetBinding(binding.asset_id, binding.name.strip(), binding.position)
            for binding in inputs
        ]
        if any(not binding.name for binding in resolved_inputs):
            raise ValueError("asset link name must not be blank")
        if any(binding.position < 0 for binding in resolved_inputs):
            raise ValueError("asset link position must not be negative")
        job_id = uuid.uuid4().hex
        now = _now()
        try:
            await self.db.execute("BEGIN")
            await self.db.execute(
                """
                INSERT INTO jobs (
                    id, kind, state, parameters_json, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?)
                """,
                (
                    job_id,
                    kind.value,
                    JobState.queued.value,
                    json.dumps(parameters, separators=(",", ":"), sort_keys=True),
                    now.isoformat(),
                    now.isoformat(),
                ),
            )
            for binding in resolved_inputs:
                cursor = await self.db.execute(
                    "SELECT 1 FROM assets WHERE id = ?",
                    (binding.asset_id,),
                )
                if await cursor.fetchone() is None:
                    raise KeyError(binding.asset_id)
                await self.db.execute(
                    """
                    INSERT INTO job_assets (
                        job_id, asset_id, direction, name, position
                    ) VALUES (?, ?, ?, ?, ?)
                    """,
                    (
                        job_id,
                        binding.asset_id,
                        AssetDirection.input.value,
                        binding.name,
                        binding.position,
                    ),
                )
            await self.db.commit()
        except Exception:
            await self.db.rollback()
            raise
        value = await self.get_job(job_id)
        assert value is not None
        return value

    @_serialized_write
    async def update_job(
        self,
        job_id: str,
        *,
        state: JobState | None = None,
        progress: float | None = None,
        progress_detail: str | None = None,
        upstream_id: str | None = None,
        cancel_requested: bool | None = None,
        error: str | None = None,
        updated_at: datetime | None = None,
    ) -> JobRecord:
        current = await self.get_job(job_id)
        if current is None:
            raise KeyError(job_id)
        values = {
            "state": (state or current.state).value,
            "progress": progress if progress is not None else current.progress,
            "progress_detail": (
                progress_detail if progress_detail is not None else current.progress_detail
            ),
            "upstream_id": upstream_id if upstream_id is not None else current.upstream_id,
            "cancel_requested": (
                int(cancel_requested)
                if cancel_requested is not None
                else int(current.cancel_requested)
            ),
            "error": error if error is not None else current.error,
            "updated_at": (updated_at or _now()).isoformat(),
        }
        await self.db.execute(
            """
            UPDATE jobs SET state=:state, progress=:progress,
                progress_detail=:progress_detail, upstream_id=:upstream_id,
                cancel_requested=:cancel_requested, error=:error,
                updated_at=:updated_at
            WHERE id=:job_id
            """,
            {**values, "job_id": job_id},
        )
        await self.db.commit()
        value = await self.get_job(job_id)
        assert value is not None
        return value

    @_serialized_write
    async def update_internal_parameters(
        self,
        job_id: str,
        values: dict[str, Any],
    ) -> JobRecord:
        current = await self.get_job(job_id)
        if current is None:
            raise KeyError(job_id)
        parameters = {
            **current.parameters,
            **{
                f"_{key}": value
                for key, value in current.internal_parameters.items()
            },
            **{
                f"_{key.removeprefix('_')}": value
                for key, value in values.items()
            },
        }
        await self.db.execute(
            """
            UPDATE jobs SET parameters_json = ?, updated_at = ?
            WHERE id = ?
            """,
            (
                json.dumps(parameters, separators=(",", ":"), sort_keys=True),
                _now().isoformat(),
                job_id,
            ),
        )
        await self.db.commit()
        updated = await self.get_job(job_id)
        assert updated is not None
        return updated

    async def get_job(self, job_id: str) -> JobRecord | None:
        cursor = await self.db.execute(
            "SELECT * FROM jobs WHERE id = ?",
            (job_id,),
        )
        row = await cursor.fetchone()
        return await self._job_from_row(row) if row is not None else None

    async def list_jobs(self) -> list[JobRecord]:
        cursor = await self.db.execute(
            "SELECT * FROM jobs ORDER BY created_at DESC"
        )
        return [await self._job_from_row(row) for row in await cursor.fetchall()]

    @_serialized_write
    async def create_asset(
        self,
        path: Path,
        media_type: str,
        filename: str,
    ) -> AssetRecord:
        root = self.asset_root.resolve()
        resolved = path.resolve()
        if not resolved.is_relative_to(root):
            raise ValueError("asset path must remain beneath asset root")
        if not resolved.is_file():
            raise ValueError("asset file does not exist")
        relative_path = str(resolved.relative_to(root))
        digest = hashlib.sha256(resolved.read_bytes()).hexdigest()
        asset_id = uuid.uuid4().hex
        await self.db.execute(
            """
            INSERT INTO assets (
                id, relative_path, filename, media_type,
                size_bytes, sha256, created_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            (
                asset_id,
                relative_path,
                filename,
                media_type,
                resolved.stat().st_size,
                digest,
                _now().isoformat(),
            ),
        )
        await self.db.commit()
        return AssetRecord(
            id=asset_id,
            relative_path=relative_path,
            filename=filename,
            media_type=media_type,
            size_bytes=resolved.stat().st_size,
            sha256=digest,
            download_url=f"/v1/assets/{asset_id}",
        )

    @_serialized_write
    async def attach_asset(
        self,
        job_id: str,
        asset_id: str,
        direction: AssetDirection,
        name: str,
        position: int = 0,
    ) -> JobRecord:
        if await self.get_job(job_id) is None:
            raise KeyError(job_id)
        if await self.get_asset(asset_id) is None:
            raise KeyError(asset_id)
        resolved_name = name.strip()
        if not resolved_name:
            raise ValueError("asset link name must not be blank")
        if position < 0:
            raise ValueError("asset link position must not be negative")
        await self.db.execute(
            """
            INSERT INTO job_assets (job_id, asset_id, direction, name, position)
            VALUES (?, ?, ?, ?, ?)
            """,
            (job_id, asset_id, direction.value, resolved_name, position),
        )
        await self.db.commit()
        value = await self.get_job(job_id)
        assert value is not None
        return value

    async def register_output(
        self,
        job_id: str,
        path: Path,
        media_type: str,
        filename: str,
        *,
        name: str = "result",
        position: int = 0,
    ) -> AssetRecord:
        assets = await self.register_outputs(
            job_id,
            [
                OutputAssetBinding(
                    path=path,
                    media_type=media_type,
                    filename=filename,
                    name=name,
                    position=position,
                )
            ],
        )
        return assets[0]

    @_serialized_write
    async def register_outputs(
        self,
        job_id: str,
        outputs: list[OutputAssetBinding] | tuple[OutputAssetBinding, ...],
        *,
        complete_job: bool = False,
    ) -> list[AssetRecord]:
        if await self.get_job(job_id) is None:
            raise KeyError(job_id)
        root = self.asset_root.resolve()
        prepared: list[tuple[AssetRecord, str, int]] = []
        for output in outputs:
            resolved = output.path.resolve()
            if not resolved.is_relative_to(root):
                raise ValueError("asset path must remain beneath asset root")
            if not resolved.is_file():
                raise ValueError("asset file does not exist")
            name = output.name.strip()
            if not name:
                raise ValueError("asset link name must not be blank")
            if output.position < 0:
                raise ValueError("asset link position must not be negative")
            asset_id = uuid.uuid4().hex
            prepared.append(
                (
                    AssetRecord(
                        id=asset_id,
                        relative_path=str(resolved.relative_to(root)),
                        filename=output.filename,
                        media_type=output.media_type,
                        size_bytes=resolved.stat().st_size,
                        sha256=hashlib.sha256(resolved.read_bytes()).hexdigest(),
                        download_url=f"/v1/assets/{asset_id}",
                    ),
                    name,
                    output.position,
                )
            )
        try:
            await self.db.execute("BEGIN")
            for asset, name, position in prepared:
                await self.db.execute(
                    """
                    INSERT INTO assets (
                        id, relative_path, filename, media_type,
                        size_bytes, sha256, created_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                    (
                        asset.id,
                        asset.relative_path,
                        asset.filename,
                        asset.media_type,
                        asset.size_bytes,
                        asset.sha256,
                        _now().isoformat(),
                    ),
                )
                await self.db.execute(
                    """
                    INSERT INTO job_assets (
                        job_id, asset_id, direction, name, position
                    ) VALUES (?, ?, ?, ?, ?)
                    """,
                    (
                        job_id,
                        asset.id,
                        AssetDirection.output.value,
                        name,
                        position,
                    ),
                )
            if complete_job:
                cursor = await self.db.execute(
                    """
                    UPDATE jobs SET state = ?, progress = ?,
                        progress_detail = NULL, updated_at = ?
                    WHERE id = ? AND cancel_requested = 0
                    """,
                    (
                        JobState.succeeded.value,
                        1.0,
                        _now().isoformat(),
                        job_id,
                    ),
                )
                if cursor.rowcount != 1:
                    raise JobCancellationRequested("job completion blocked by cancellation")
            await self.db.commit()
        except Exception:
            await self.db.rollback()
            raise
        return [asset for asset, _, _ in prepared]

    async def get_asset(self, asset_id: str) -> tuple[AssetRecord, Path] | None:
        cursor = await self.db.execute("SELECT * FROM assets WHERE id = ?", (asset_id,))
        row = await cursor.fetchone()
        if row is None:
            return None
        record = self._asset_from_row(row)
        path = (self.asset_root / record.relative_path).resolve()
        if not path.is_relative_to(self.asset_root.resolve()):
            return None
        return record, path

    async def cancel_job(self, job_id: str) -> JobRecord:
        current = await self.get_job(job_id)
        if current is None:
            raise KeyError(job_id)
        if current.state in TERMINAL_STATES:
            return current
        if current.state is JobState.queued:
            return await self.update_job(job_id, state=JobState.cancelled)
        return await self.update_job(job_id, cancel_requested=True)

    async def recover_jobs(self) -> list[str]:
        recovered: list[str] = []
        for job in await self.list_jobs():
            if job.state is JobState.queued:
                recovered.append(job.id)
            elif job.state is JobState.acquiring_gpu:
                await self.update_job(job.id, state=JobState.queued)
                recovered.append(job.id)
            elif job.state is JobState.running:
                if job.kind is JobKind.generation and job.upstream_id:
                    await self.update_job(job.id, state=JobState.queued)
                    recovered.append(job.id)
                else:
                    await self.update_job(
                        job.id,
                        state=JobState.failed,
                        error="Job was interrupted by a gateway restart; retry the job.",
                    )
        return recovered

    @_serialized_write
    async def prune_assets(self, *, older_than: datetime) -> int:
        cursor = await self.db.execute(
            """
            SELECT assets.id, assets.relative_path
            FROM assets
            WHERE NOT EXISTS (
                SELECT 1 FROM job_assets
                JOIN jobs ON jobs.id = job_assets.job_id
                WHERE job_assets.asset_id = assets.id
                  AND (
                      jobs.state NOT IN (?, ?, ?)
                      OR jobs.updated_at >= ?
                  )
            )
              AND (
                  assets.created_at < ?
                  OR EXISTS (
                      SELECT 1 FROM job_assets
                      JOIN jobs ON jobs.id = job_assets.job_id
                      WHERE job_assets.asset_id = assets.id
                        AND jobs.state IN (?, ?, ?)
                        AND jobs.updated_at < ?
                  )
              )
            """,
            (
                JobState.succeeded.value,
                JobState.failed.value,
                JobState.cancelled.value,
                older_than.isoformat(),
                older_than.isoformat(),
                JobState.succeeded.value,
                JobState.failed.value,
                JobState.cancelled.value,
                older_than.isoformat(),
            ),
        )
        rows = await cursor.fetchall()
        for row in rows:
            path = (self.asset_root / row["relative_path"]).resolve()
            if path.is_relative_to(self.asset_root.resolve()):
                path.unlink(missing_ok=True)
            await self.db.execute("DELETE FROM assets WHERE id = ?", (row["id"],))
        await self.db.commit()
        return len(rows)

    async def _job_from_row(self, row: aiosqlite.Row) -> JobRecord:
        cursor = await self.db.execute(
            """
            SELECT job_assets.direction, job_assets.name AS link_name,
                   job_assets.position, assets.*
            FROM job_assets JOIN assets ON assets.id = job_assets.asset_id
            WHERE job_assets.job_id = ?
            ORDER BY job_assets.direction, job_assets.position, job_assets.name
            """,
            (row["id"],),
        )
        inputs: list[JobAssetLink] = []
        outputs: list[JobAssetLink] = []
        for link_row in await cursor.fetchall():
            link = JobAssetLink(
                name=link_row["link_name"],
                position=link_row["position"],
                asset=self._asset_from_row(link_row),
            )
            if link_row["direction"] == AssetDirection.input.value:
                inputs.append(link)
            else:
                outputs.append(link)
        raw_parameters = json.loads(row["parameters_json"])
        return JobRecord(
            id=row["id"],
            kind=JobKind(row["kind"]),
            state=JobState(row["state"]),
            parameters={key: value for key, value in raw_parameters.items() if not key.startswith("_")},
            internal_parameters={
                key.removeprefix("_"): value
                for key, value in raw_parameters.items()
                if key.startswith("_")
            },
            progress=row["progress"],
            progress_detail=row["progress_detail"],
            upstream_id=row["upstream_id"],
            cancel_requested=bool(row["cancel_requested"]),
            error=row["error"],
            created_at=datetime.fromisoformat(row["created_at"]),
            updated_at=datetime.fromisoformat(row["updated_at"]),
            inputs=inputs,
            outputs=outputs,
            asset=outputs[0].asset if outputs else None,
        )

    def _asset_from_row(self, row: aiosqlite.Row) -> AssetRecord:
        return AssetRecord(
            id=row["id"],
            relative_path=row["relative_path"],
            filename=row["filename"],
            media_type=row["media_type"],
            size_bytes=row["size_bytes"],
            sha256=row["sha256"],
            download_url=f"/v1/assets/{row['id']}",
        )
