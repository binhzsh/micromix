# Durable Asset Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [x]`) syntax for tracking.

**Goal:** Make Micromix jobs support reusable input assets, multiple named output
assets, and backward-compatible provenance without changing either inference
worker yet.

**Architecture:** Store physical assets independently from jobs and relate them
through a `job_assets` association table carrying direction, name, and position.
Migrate the deployed one-output schema in place, retain the legacy `asset` JSON
field as the first output, and add `inputs`/`outputs` arrays. A multipart asset
upload endpoint creates reusable transient inputs under the existing asset root.

**Tech Stack:** Python 3.12, FastAPI, Pydantic 2, aiosqlite/SQLite, pytest,
Docker/uv on `lts1`.

**Spec:** `docs/superpowers/specs/2026-08-30-micromix-inference-roadmap-design.md`

**Status:** complete, merged to `main`, and deployed on `lts1` on 2026-08-30.
Backend verification passed all 33 tests and the live schema/asset-link smoke
check.

## Global Constraints

- Perform Python, FastAPI, Docker, and inference-stack edits on the `lts1`
  worktree at `~/apps/micromix/.worktrees/phase1-reimagine`.
- Follow test-driven development: add one failing behavioral test, observe the
  expected failure, then add the minimum production change.
- Preserve existing `/v1/jobs/generation`, `/v1/jobs/transcription`, and
  `/v1/assets/{id}` clients during migration.
- The Mac library remains authoritative; server assets remain transient and
  subject to retention.
- Never expose server filesystem paths in API responses.
- Do not modify ACE-Step or MuScriptor behavior in this plan.
- Do not deploy until the complete backend suite passes in the isolated
  worktree.

## File structure

- Modify `services/micromix-api/micromix_api/models.py` to define public asset
  direction/link records and the backward-compatible job response.
- Modify `services/micromix-api/micromix_api/store.py` to own schema migration,
  standalone asset registration, associations, hydration, and retention.
- Modify `services/micromix-api/micromix_api/main.py` to add validated multipart
  asset upload.
- Modify `services/micromix-api/micromix_api/coordinator.py` to register named
  outputs through the new store contract.
- Modify `services/micromix-api/tests/test_store.py` for migration, reuse,
  ordering, and retention behavior.
- Modify `services/micromix-api/tests/test_api.py` for public request/response
  compatibility and upload validation.
- Modify `services/micromix-api/tests/test_coordinator.py` for named output
  registration.
- Modify `README.md` to document the additive asset API and response shape.

---

### Task 1: Public asset-link contract

**Files:**

- Modify: `services/micromix-api/micromix_api/models.py`
- Test: `services/micromix-api/tests/test_store.py`

**Interfaces:**

- Produces: `AssetDirection`, `JobAssetLink`, `JobRecord.inputs`,
  `JobRecord.outputs`, and deprecated compatibility field `JobRecord.asset`.
- `JobAssetLink` contains `name: str`, `position: int`, and
  `asset: AssetRecord`.
- `JobRecord.asset` equals the first output asset or `None`.

- [x] **Step 1: Add a failing response-model test**

Append this test to `tests/test_store.py` after importing `AssetDirection`:

```python
def test_asset_direction_uses_stable_wire_values():
    assert AssetDirection.input.value == "input"
    assert AssetDirection.output.value == "output"
```

- [x] **Step 2: Run the focused test and verify RED**

Run from `services/micromix-api` on `lts1`:

```bash
docker run --rm --user "$(id -u):$(id -g)" \
  -e UV_PROJECT_ENVIRONMENT=/tmp/micromix-venv \
  -e UV_CACHE_DIR=/tmp/uv-cache -v "$PWD:/app" -w /app \
  ghcr.io/astral-sh/uv:0.7.22-python3.12-bookworm \
  uv run --frozen --group dev python -m pytest \
  tests/test_store.py::test_asset_direction_uses_stable_wire_values -q
```

Expected: collection fails because `AssetDirection` does not exist.

- [x] **Step 3: Add the minimal public models**

In `models.py`, define:

```python
class AssetDirection(str, Enum):
    input = "input"
    output = "output"


class JobAssetLink(BaseModel):
    model_config = ConfigDict(extra="forbid")

    name: str
    position: int
    asset: AssetRecord
```

Change the end of `JobRecord` to:

```python
    inputs: list[JobAssetLink] = Field(default_factory=list)
    outputs: list[JobAssetLink] = Field(default_factory=list)
    asset: AssetRecord | None = None
```

- [x] **Step 4: Run the focused test and verify GREEN**

Run the command from Step 2. Expected: one test passes.

- [x] **Step 5: Commit the model contract**

```bash
git add services/micromix-api/micromix_api/models.py \
  services/micromix-api/tests/test_store.py
git commit -m "feat(api): define job asset links"
```

### Task 2: Schema migration and multi-asset persistence

**Files:**

- Modify: `services/micromix-api/micromix_api/store.py`
- Test: `services/micromix-api/tests/test_store.py`

**Interfaces:**

- Produces: `JobStore.create_asset(path, media_type, filename) -> AssetRecord`.
- Produces: `JobStore.attach_asset(job_id, asset_id, direction, name,
  position=0) -> JobRecord`.
- Produces: `JobStore.register_output(job_id, path, media_type, filename,
  name="result", position=0) -> AssetRecord`.
- Temporarily retains `register_asset(job_id, path, media_type, filename)` as a
  compatibility wrapper around `register_output` until Task 5 migrates callers.
- Existing databases migrate atomically from `assets.job_id UNIQUE` to
  standalone `assets` plus `job_assets`.

- [x] **Step 1: Add a failing multiple-output and reusable-input test**

Replace the existing single-asset lifecycle assertions with explicit link
assertions and add:

```python
@pytest.mark.asyncio
async def test_asset_can_feed_two_jobs_and_each_job_can_have_multiple_outputs(store: JobStore):
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
            first.id, path, "audio/wav", name, name="variation", position=position
        )

    persisted_first = await store.get_job(first.id)
    persisted_second = await store.get_job(second.id)
    assert [link.asset.id for link in persisted_first.inputs] == [source.id]
    assert [link.asset.filename for link in persisted_first.outputs] == [
        "take-1.wav",
        "take-2.wav",
    ]
    assert persisted_first.asset == persisted_first.outputs[0].asset
    assert [link.asset.id for link in persisted_second.inputs] == [source.id]
```

- [x] **Step 2: Run the new test and verify RED**

Run the containerized focused test. Expected: `create_asset` or `attach_asset`
is missing.

- [x] **Step 3: Implement the normalized schema**

Define `assets` without `job_id` and add:

```sql
CREATE TABLE IF NOT EXISTS job_assets (
    job_id TEXT NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
    asset_id TEXT NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
    direction TEXT NOT NULL CHECK(direction IN ('input', 'output')),
    name TEXT NOT NULL,
    position INTEGER NOT NULL DEFAULT 0 CHECK(position >= 0),
    PRIMARY KEY (job_id, direction, name, position),
    UNIQUE (job_id, asset_id, direction)
);

CREATE INDEX IF NOT EXISTS job_assets_asset_idx ON job_assets(asset_id);
```

During `open()`, inspect `PRAGMA table_info(assets)`. When legacy column
`job_id` exists, run one transaction that renames the table, creates the new
tables, copies every physical asset, inserts one `output/result/0` association
for each legacy row, drops the legacy table, and sets `PRAGMA user_version=1`.
New databases create the normalized tables directly.

Implement the store methods in the Interfaces block. Validate that the
physical path stays below `asset_root`, the file exists, both job and asset
exist before association, names are nonblank, and positions are nonnegative.

- [x] **Step 4: Hydrate links without row multiplication**

Load the job row independently, then query links ordered by
`direction, position, name`. Construct `inputs` and `outputs`, and set `asset`
to `outputs[0].asset` when present. Keep internal underscore-prefixed parameters
excluded from public JSON.

- [x] **Step 5: Add and pass a legacy migration test**

Create a SQLite database in the test with the old `jobs` and `assets` schema,
one succeeded job, and one output row. Open it with `JobStore`, then assert the
job has one `outputs` link named `result`, `asset` matches it, the file remains
downloadable, and `PRAGMA user_version` is `1`. Run the focused migration test
first to observe its expected RED, implement only migration fixes, then rerun it
to GREEN.

- [x] **Step 6: Run all store tests, then the complete backend suite**

Run `python -m pytest tests/test_store.py -q`, then `python -m pytest -q`
through the container. Expected: both commands pass.

- [x] **Step 7: Commit persistence and migration**

```bash
git add services/micromix-api/micromix_api/store.py \
  services/micromix-api/tests/test_store.py
git commit -m "feat(api): persist reusable job assets"
```

### Task 3: Retention across shared assets

**Files:**

- Modify: `services/micromix-api/micromix_api/store.py`
- Test: `services/micromix-api/tests/test_store.py`

**Interfaces:**

- `prune_assets(older_than)` removes an asset only when it is old and no active
  or recent associated job still needs it.
- Unassociated uploads use asset `created_at` for expiration.

- [x] **Step 1: Add failing shared-retention tests**

Add one test in which an old terminal job and a recent queued job share an input;
assert pruning retains that input. Add another old, unassociated uploaded asset
and assert pruning deletes its file and row.

- [x] **Step 2: Run both tests and verify RED**

Expected: the old shared input is deleted or the unassociated upload is not
deleted under the legacy pruning query.

- [x] **Step 3: Implement reference-aware pruning**

Select asset rows older than the cutoff that have no association to a job whose
state is nonterminal or whose `updated_at` is at/after the cutoff. Delete the
physical file only after verifying it remains inside `asset_root`, then delete
the asset row so foreign-key cascades remove associations.

- [x] **Step 4: Run all store tests and the complete suite; verify GREEN**

Run `python -m pytest tests/test_store.py -q`, then `python -m pytest -q`
through the container.

- [x] **Step 5: Commit retention behavior**

```bash
git add services/micromix-api/micromix_api/store.py \
  services/micromix-api/tests/test_store.py
git commit -m "fix(api): retain shared active assets"
```

### Task 4: Validated reusable asset upload API

**Files:**

- Modify: `services/micromix-api/micromix_api/main.py`
- Test: `services/micromix-api/tests/test_api.py`

**Interfaces:**

- Produces: `POST /v1/assets` multipart field `audio_file` returning
  `AssetRecord` with HTTP 201.
- Uploaded files live at `asset_root/imports/<upload-id>/<safe-filename>`.
- Enforces the existing `MAX_UPLOAD_MIB`, rejects empty uploads, strips path
  components, and never returns a filesystem path.

- [x] **Step 1: Add a failing successful-upload test**

```python
@pytest.mark.asyncio
async def test_audio_asset_upload_is_downloadable_and_hides_server_path(client):
    response = await client.post(
        "/v1/assets",
        files={"audio_file": ("../source.wav", b"RIFF-input", "audio/wav")},
    )
    assert response.status_code == 201
    asset = response.json()
    assert asset["filename"] == "source.wav"
    assert asset["media_type"] == "audio/wav"
    assert "relative_path" not in asset
    downloaded = await client.get(asset["download_url"])
    assert downloaded.content == b"RIFF-input"
```

- [x] **Step 2: Run the test and verify RED**

Expected: HTTP 404 because `POST /v1/assets` does not exist.

- [x] **Step 3: Implement the minimal upload endpoint**

Read and validate bytes using the same empty/maximum-size rules as transcription.
Create an unpredictable import directory under `asset_root/imports`, write the
basename-only filename, call `create_asset`, and return `AssetRecord` with
HTTP 201. Remove the just-created directory if registration fails.

- [x] **Step 4: Add failing validation tests, then implement GREEN behavior**

Set `max_upload_mib=1` in the API test fixture. Add tests for an empty upload
(HTTP 400) and a payload of `(1024 * 1024) + 1` bytes (HTTP 413). Observe each
fail before updating shared upload validation. Keep the full body out of public
parameters and errors.

- [x] **Step 5: Run all API tests, then the complete backend suite**

Run `python -m pytest tests/test_api.py -q`, then `python -m pytest -q`
through the container.

- [x] **Step 6: Commit the upload endpoint**

```bash
git add services/micromix-api/micromix_api/main.py \
  services/micromix-api/tests/test_api.py
git commit -m "feat(api): accept reusable audio assets"
```

### Task 5: Migrate current producers and preserve API compatibility

**Files:**

- Modify: `services/micromix-api/micromix_api/coordinator.py`
- Modify: `services/micromix-api/tests/test_coordinator.py`
- Modify: `services/micromix-api/tests/test_api.py`
- Modify: `README.md`

**Interfaces:**

- Generation outputs use link name `result` and position `0`.
- Transcription outputs use link name `midi` and position `0`.
- Existing `asset` response remains identical to the first output asset.
- New `inputs` and `outputs` arrays are additive.

- [x] **Step 1: Update coordinator tests first**

Change assertions to require `completed.outputs[0].name == "result"` for
generation and `completed.outputs[0].name == "midi"` for transcription. Assert
`completed.asset == completed.outputs[0].asset`. Run both focused tests and
observe RED because the current coordinator calls the old registration method.

- [x] **Step 2: Migrate producer calls**

Replace `register_asset(job.id, ...)` with `register_output(...)`, using the
stable names and positions from Interfaces. Remove the internal compatibility
wrapper after `rg 'register_asset' services/micromix-api` confirms it has no
remaining production callers. Make no worker or inference changes.

- [x] **Step 3: Add API compatibility assertions**

For a store-populated completed job, assert GET `/v1/jobs/{id}` contains
`inputs: []`, one item in `outputs`, and an `asset` object equal to
`outputs[0].asset`. Also assert queued jobs still return `asset: null`.

- [x] **Step 4: Run all backend tests**

Run:

```bash
docker run --rm --user "$(id -u):$(id -g)" \
  -e UV_PROJECT_ENVIRONMENT=/tmp/micromix-venv \
  -e UV_CACHE_DIR=/tmp/uv-cache -v "$PWD:/app" -w /app \
  ghcr.io/astral-sh/uv:0.7.22-python3.12-bookworm \
  uv run --frozen --group dev python -m pytest -q
```

Expected: all tests pass.

- [x] **Step 5: Document the additive API**

In `README.md`, add `POST /v1/assets`, explain `inputs`/`outputs`, mark `asset`
as the compatibility alias for the first output, and state that uploads and
outputs share seven-day transient retention.

- [x] **Step 6: Commit compatibility and docs**

```bash
git add services/micromix-api/micromix_api/coordinator.py \
  services/micromix-api/tests/test_coordinator.py \
  services/micromix-api/tests/test_api.py README.md
git commit -m "refactor(api): emit named job outputs"
```

### Task 6: Isolated deployment verification

**Files:**

- Modify only if verification finds a tested defect.

**Interfaces:**

- The migration must open a copy of the deployed database without data loss.
- Existing generation/transcription clients continue to decode `asset`.

- [x] **Step 1: Run migration rehearsal against a database copy**

Stop no services. Locate the live `/data` mount without reading `.env`, use
SQLite's online backup API from a temporary Python container, and place the copy
in a temporary directory:

```bash
gateway_data=$(docker inspect micromix-api --format \
  '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Source}}{{end}}{{end}}')
migration_rehearsal=$(mktemp -d)
docker run --rm -v "$gateway_data:/source:ro" \
  -v "$migration_rehearsal:/backup" python:3.12-slim \
  python -c 'import sqlite3; source=sqlite3.connect("file:/source/gateway.db?mode=ro", uri=True); target=sqlite3.connect("/backup/gateway.db"); source.backup(target); target.close(); source.close()'
```

Record job and asset counts on the copy, open only the copy with `JobStore`,
then verify the counts are unchanged and every legacy asset has one
`output/result/0` association. Delete the temporary rehearsal directory after
the counts have been recorded in the checkpoint report.

- [x] **Step 2: Run the complete backend suite again**

Use the Task 5 container command. Expected: all tests pass with no warnings or
collection errors.

- [x] **Step 3: Push and fast-forward the local feature worktree**

Push `feat/phase1-reimagine` from `lts1`, then in the Mac worktree run
`git pull --ff-only`. Confirm both worktrees and `origin/feat/phase1-reimagine`
resolve to the same commit.

- [x] **Step 4: Check the macOS compatibility suite**

From `MacOS` in the local feature worktree, regenerate the ignored project and
run:

```bash
xcodegen generate
xcodebuild test -project Micromix.xcodeproj -scheme Micromix \
  -destination 'platform=macOS'
```

Expected: all 42 existing tests pass because the legacy `asset` field remains.

- [x] **Step 5: Stop for review before deployment**

Report migration counts, backend test count, macOS test count, exact commit,
and any API differences. Do not run `docker compose up -d --build` until this
checkpoint is reviewed.

Checkpoint recorded 2026-08-30:

- Migration rehearsal preserved 18 jobs and 12 assets.
- All 12 legacy assets received one `output/result/0` association; zero were
  orphaned; schema version advanced to 1.
- Backend verification: 33 tests passed.
- macOS compatibility verification: 42 tests passed.
- Feature code checkpoint: `d70d4eb`.
- Live service was not rebuilt or restarted.
