from __future__ import annotations

import hashlib
import json
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import aiosqlite

from .models import AssetRecord, JobKind, JobRecord, JobState, TERMINAL_STATES


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
    job_id TEXT NOT NULL UNIQUE REFERENCES jobs(id) ON DELETE CASCADE,
    relative_path TEXT NOT NULL UNIQUE,
    filename TEXT NOT NULL,
    media_type TEXT NOT NULL,
    size_bytes INTEGER NOT NULL,
    sha256 TEXT NOT NULL,
    created_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS jobs_state_created_idx ON jobs(state, created_at);
"""


def _now() -> datetime:
    return datetime.now(timezone.utc)


class JobStore:
    def __init__(self, database_path: Path, asset_root: Path):
        self.database_path = database_path
        self.asset_root = asset_root
        self._db: aiosqlite.Connection | None = None

    async def open(self) -> None:
        self.database_path.parent.mkdir(parents=True, exist_ok=True)
        self.asset_root.mkdir(parents=True, exist_ok=True)
        self._db = await aiosqlite.connect(self.database_path)
        self._db.row_factory = aiosqlite.Row
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

    async def create_job(self, kind: JobKind, parameters: dict[str, Any]) -> JobRecord:
        job_id = uuid.uuid4().hex
        now = _now()
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
        await self.db.commit()
        value = await self.get_job(job_id)
        assert value is not None
        return value

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

    async def get_job(self, job_id: str) -> JobRecord | None:
        cursor = await self.db.execute(
            """
            SELECT jobs.*, assets.id AS asset_id, assets.relative_path,
                   assets.filename, assets.media_type, assets.size_bytes,
                   assets.sha256
            FROM jobs LEFT JOIN assets ON assets.job_id = jobs.id
            WHERE jobs.id = ?
            """,
            (job_id,),
        )
        row = await cursor.fetchone()
        return self._job_from_row(row) if row is not None else None

    async def list_jobs(self) -> list[JobRecord]:
        cursor = await self.db.execute(
            """
            SELECT jobs.*, assets.id AS asset_id, assets.relative_path,
                   assets.filename, assets.media_type, assets.size_bytes,
                   assets.sha256
            FROM jobs LEFT JOIN assets ON assets.job_id = jobs.id
            ORDER BY jobs.created_at DESC
            """
        )
        return [self._job_from_row(row) for row in await cursor.fetchall()]

    async def register_asset(
        self,
        job_id: str,
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
                id, job_id, relative_path, filename, media_type,
                size_bytes, sha256, created_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                asset_id,
                job_id,
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

    async def prune_assets(self, *, older_than: datetime) -> int:
        cursor = await self.db.execute(
            """
            SELECT assets.id, assets.relative_path FROM assets
            JOIN jobs ON jobs.id = assets.job_id
            WHERE jobs.state IN (?, ?, ?) AND jobs.updated_at < ?
            """,
            (
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

    def _job_from_row(self, row: aiosqlite.Row) -> JobRecord:
        asset = None
        if row["asset_id"] is not None:
            asset = AssetRecord(
                id=row["asset_id"],
                relative_path=row["relative_path"],
                filename=row["filename"],
                media_type=row["media_type"],
                size_bytes=row["size_bytes"],
                sha256=row["sha256"],
                download_url=f"/v1/assets/{row['asset_id']}",
            )
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
            asset=asset,
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
