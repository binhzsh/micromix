# ACE Reimagine Operations Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add durable reference generation, Remix/Cover, Repaint, deterministic
variations, and bounded upstream recovery to the Micromix gateway.

**Architecture:** Keep every operation as a `generation` job and distinguish it
with typed public parameters plus named durable input links. Extend the ACE
adapter to send source files by multipart and return all outputs. Persist one
hidden recovery counter so a vanished upstream task is resubmitted exactly once.

**Tech Stack:** Python 3.12, FastAPI, Pydantic 2, aiosqlite/SQLite, httpx,
pytest, Docker Compose, ACE-Step 1.5 pinned commit.

**Spec:** `docs/superpowers/specs/2026-08-30-ace-reimagine-operations-design.md`

## Global Constraints

- Perform Python, FastAPI, Docker, and inference edits only on `lts1` in an
  isolated worktree based on current `origin/main`.
- Preserve `POST /v1/jobs/generation` and the singular `JobRecord.asset` alias.
- Accept one through four variations and persist every effective seed.
- Never expose an asset filesystem path in an API response.
- Keep the Mac library authoritative and server assets subject to retention.
- Do not add ACE models, revise the pinned ACE commit, or add Logic-overlapping
  separation, tuning, mixing, or mastering.
- Follow red-green-refactor for every production behavior.

Run backend tests from `services/micromix-api` with:

```bash
docker run --rm --user "$(id -u):$(id -g)" \
  -e UV_PROJECT_ENVIRONMENT=/tmp/micromix-venv \
  -e UV_CACHE_DIR=/tmp/uv-cache -v "$PWD:/app" -w /app \
  ghcr.io/astral-sh/uv:0.7.22-python3.12-bookworm \
  uv run --frozen --group dev python -m pytest -q
```

For a focused red-green cycle, place the test path and optional `::test_name`
immediately before `-q` in the final line.

---

### Task 1: Typed requests and deterministic seed resolution

**Files:**

- Modify: `services/micromix-api/micromix_api/models.py`
- Create: `services/micromix-api/micromix_api/generation.py`
- Test: `services/micromix-api/tests/test_generation.py`

**Interfaces:**

- Produces `GenerationOperation`, `ReferenceGenerationRequest`, `RemixRequest`,
  and `RepaintRequest`.
- Produces `resolve_variation_seeds(seed: int | None, count: int) -> list[int]`.
- Existing `GenerationRequest` gains `variation_count: int = Field(1, ge=1,
  le=4)` and constrains `seed` to unsigned 32-bit range.

- [ ] **Step 1: Write failing request and seed tests**

Add literal assertions covering:

```python
def test_explicit_variation_seeds_are_consecutive_and_wrap():
    assert resolve_variation_seeds(4_294_967_295, 3) == [4_294_967_295, 0, 1]


def test_random_variation_seeds_are_valid_and_independent(monkeypatch):
    values = iter([11, 22])
    monkeypatch.setattr("micromix_api.generation.secrets.randbelow", lambda _: next(values))
    assert resolve_variation_seeds(None, 2) == [11, 22]


def test_repaint_rejects_interval_shorter_than_three_seconds():
    with pytest.raises(ValidationError):
        RepaintRequest(
            source_asset_id="source",
            prompt="piano bridge",
            start_seconds=4,
            end_seconds=6,
        )
```

Also assert valid defaults and the 90-second maximum for the three new request
models.

- [ ] **Step 2: Run the focused tests and verify RED**

Run the service's frozen containerized pytest command for
`tests/test_generation.py`. Expected: import failure because the new models and
helper do not exist.

- [ ] **Step 3: Implement the minimal models and helper**

Use a shared base request for prompt, lyrics, preset, seed, and
`variation_count`. Validate repaint interval duration in an
`@model_validator(mode="after")`. Implement seed wrapping with modulus
`2**32`; use `secrets.randbelow(2**32)` when no seed is supplied.

- [ ] **Step 4: Run focused tests and verify GREEN**

- [ ] **Step 5: Commit**

```bash
git add services/micromix-api/micromix_api/models.py \
  services/micromix-api/micromix_api/generation.py \
  services/micromix-api/tests/test_generation.py
git commit -m "feat(api): define reimagine requests"
```

### Task 2: Atomic jobs with inputs and internal recovery state

**Files:**

- Modify: `services/micromix-api/micromix_api/store.py`
- Test: `services/micromix-api/tests/test_store.py`

**Interfaces:**

- Produces `InputAssetBinding(asset_id, name, position=0)`.
- Extends `create_job(kind, parameters, *, inputs=())` to insert the job and all
  input links in one transaction.
- Produces `update_internal_parameters(job_id, values) -> JobRecord`.
- Produces `register_outputs(job_id, outputs) -> list[AssetRecord]`, where each
  output contains path, media type, filename, name, and position.
- Keeps `register_output` as a one-item wrapper.

- [ ] **Step 1: Write failing atomic input tests**

Test that one source asset is attached during job creation and that a missing
asset rolls back the job row. Assert public parameters omit
`_upstream_recovery_count` while `internal_parameters` includes it.

- [ ] **Step 2: Run the focused tests and verify RED**

Expected: `create_job` rejects the `inputs` keyword.

- [ ] **Step 3: Implement transactional create-with-inputs**

Validate names and positions before `BEGIN`; insert the job and links; commit
only after all inserts succeed; rollback on every exception. Do not call
`get_job` from inside the transaction.

- [ ] **Step 4: Run focused tests and verify GREEN**

- [ ] **Step 5: Write failing internal-update and batch-output tests**

Assert underscore-prefixed state persists without changing public parameters.
Assert two outputs appear in position order, and an invalid second output rolls
back both asset records and links.

- [ ] **Step 6: Run tests and verify RED**

- [ ] **Step 7: Implement internal updates and atomic batch registration**

Merge hidden values into `parameters_json`. Pre-validate every output path under
`asset_root`, calculate metadata, then insert all records and links in one
transaction. Preserve the current compatibility wrapper.

- [ ] **Step 8: Run focused and full store tests and verify GREEN**

- [ ] **Step 9: Commit**

```bash
git add services/micromix-api/micromix_api/store.py \
  services/micromix-api/tests/test_store.py
git commit -m "feat(api): create source jobs atomically"
```

### Task 3: Typed submission endpoints

**Files:**

- Modify: `services/micromix-api/micromix_api/main.py`
- Test: `services/micromix-api/tests/test_api.py`

**Interfaces:**

- Produces `POST /v1/jobs/reference-generation`.
- Produces `POST /v1/jobs/remix`.
- Produces `POST /v1/jobs/repaint`.
- Stores `operation`, `variation_count`, `seeds`, and
  `_upstream_recovery_count=0`.

- [ ] **Step 1: Write failing endpoint contract tests**

Upload an audio asset, submit each new route, and assert HTTP 202, the expected
public operation/seed values, and the `reference` or `source` input link. Submit
an explicit maximum seed with two variations and assert wraparound literally.

- [ ] **Step 2: Run endpoint tests and verify RED**

Expected: HTTP 404 for the new routes.

- [ ] **Step 3: Implement shared asset validation and route submission**

Resolve the asset before creating a job. Return 404 for an unknown asset and 422
unless its media type starts with `audio/` or equals
`application/octet-stream`. Build public parameters from
`model_dump(exclude_none=True, exclude={...asset id...})`, add operation/seeds,
and create the job with one `InputAssetBinding`.

- [ ] **Step 4: Run endpoint tests and verify GREEN**

- [ ] **Step 5: Write and pass negative contract tests**

Cover missing assets, non-audio assets, invalid variation counts, strengths, and
repaint intervals. Assert job listing remains unchanged after each rejected
request.

- [ ] **Step 6: Update existing generation submission behavior**

Add `operation="text"`, persisted seeds, recovery count, and explicit default
variation count while preserving all previous accepted payloads.

- [ ] **Step 7: Run the complete API tests and verify GREEN**

- [ ] **Step 8: Commit**

```bash
git add services/micromix-api/micromix_api/main.py \
  services/micromix-api/tests/test_api.py
git commit -m "feat(api): accept reimagine jobs"
```

### Task 4: Multipart ACE submission and ordered result batches

**Files:**

- Modify: `services/micromix-api/micromix_api/adapters.py`
- Test: `services/micromix-api/tests/test_adapters.py`

**Interfaces:**

- Produces `UpstreamOutput(data, filename, media_type)` in `coordinator.py`.
- Extends `ACEClient.submit(parameters, *, reference_audio=None,
  source_audio=None)`.
- `ACEClient.poll` returns running, missing, failed, or succeeded with an ordered
  tuple of outputs.

- [ ] **Step 1: Write a failing text submission regression**

Assert existing generation now sends `batch_size=1`,
`use_random_seed=false`, and the exact comma-separated seed payload derived from
the recorded seed list.

- [ ] **Step 2: Run and verify RED**

- [ ] **Step 3: Implement explicit text batch and seed mapping**

Keep JSON submission when there is no audio file. Map all existing metadata and
presets unchanged.

- [ ] **Step 4: Run and verify GREEN**

- [ ] **Step 5: Write failing multipart operation tests**

For each operation, inspect the real httpx request body and assert the correct
file field (`reference_audio` or `src_audio`), task type, strength/range fields,
batch size, and seed string. Use complete temporary audio fixtures.

- [ ] **Step 6: Implement multipart submission**

Open files only for the duration of `client.post`. Form values are strings;
filenames use `Path.name`; media type is `application/octet-stream`. Reject a
call that provides both reference and source paths.

- [ ] **Step 7: Run and verify GREEN**

- [ ] **Step 8: Write failing ordered polling tests**

Return two upstream audio paths and assert both downloads, order, filenames, and
media types. Separately assert `result="[]"` becomes `missing`, while a result
list containing a status-zero item remains `running`.

- [ ] **Step 9: Implement batch polling and missing-state detection**

Require every success row to contain a file. Download all rows in order. A
nonempty status-zero result remains running.

- [ ] **Step 10: Run all adapter tests and verify GREEN**

- [ ] **Step 11: Commit**

```bash
git add services/micromix-api/micromix_api/adapters.py \
  services/micromix-api/micromix_api/coordinator.py \
  services/micromix-api/tests/test_adapters.py
git commit -m "feat(api): submit ACE source audio"
```

### Task 5: Coordinator inputs, outputs, and bounded recovery

**Files:**

- Modify: `services/micromix-api/micromix_api/coordinator.py`
- Test: `services/micromix-api/tests/test_coordinator.py`

**Interfaces:**

- Resolves the `reference` or `source` job input to a safe local path.
- Registers exactly `variation_count` outputs atomically.
- Resubmits an unknown upstream task once and persists the recovery count.

- [ ] **Step 1: Write a failing named-input submission test**

Create a durable input asset and source-linked Remix job. Assert the fake ACE
client receives the source path and no reference path.

- [ ] **Step 2: Run and verify RED**

- [ ] **Step 3: Implement operation-specific input resolution**

Use the named job input links and `store.get_asset`; fail explicitly if the link
or physical file is unavailable. Pass keyword paths to `ACEClient.submit`.

- [ ] **Step 4: Run and verify GREEN**

- [ ] **Step 5: Write a failing multiple-output test**

Return two literal output payloads. Assert stable `result-1.wav` and
`result-2.wav` names, positions zero and one, distinct bytes, and first-output
compatibility alias.

- [ ] **Step 6: Implement exact-count batch output registration**

Reject count mismatch. Stage all files, call `register_outputs` once, and clean
the staging directory if registration or a write fails.

- [ ] **Step 7: Run and verify GREEN**

- [ ] **Step 8: Write failing bounded-recovery tests**

Test `missing -> succeeded` causes one resubmission using identical inputs and
seeds and persists count one. Test a job beginning with count one and returning
`missing` becomes failed without another submission.

- [ ] **Step 9: Implement durable one-time recovery**

Increment the hidden counter before resubmission, replace `upstream_id`, and
continue polling. Emit `ACE-Step task disappeared after recovery` on the bounded
failure path.

- [ ] **Step 10: Extend cancellation and partial-failure tests**

Assert cancellation registers no batch outputs. Assert count mismatch and batch
registration failure leave no output files or asset links.

- [ ] **Step 11: Run coordinator tests and the complete backend suite**

- [ ] **Step 12: Commit**

```bash
git add services/micromix-api/micromix_api/coordinator.py \
  services/micromix-api/tests/test_coordinator.py
git commit -m "feat(api): persist reimagine output batches"
```

### Task 6: Documentation, full verification, integration, and deployment

**Files:**

- Modify: `README.md`
- Modify: `docs/superpowers/plans/2026-08-31-ace-reimagine-operations.md`

**Interfaces:** Documents exact routes, parameters, asset links, retention, and
the Logic handoff boundary.

- [ ] **Step 1: Update the README**

Add all three routes and concise `curl` examples that first upload an asset and
then reference its ID. Document ordered outputs and effective seeds.

- [ ] **Step 2: Run documentation and repository checks**

```bash
git diff --check
```

- [ ] **Step 3: Run the full backend suite fresh**

Use the frozen `uv` container command from the repository workflow. Require zero
failures.

- [ ] **Step 4: Commit documentation and checked plan state**

```bash
git add README.md docs/superpowers/plans/2026-08-31-ace-reimagine-operations.md
git commit -m "docs: describe reimagine job contracts"
```

- [ ] **Step 5: Merge with fast-forward and push**

Verify both checkouts are clean and current. Fast-forward `main` to the feature
branch, push `origin/main`, and pull `--ff-only` into the other checkout. Never
force or reset.

- [ ] **Step 6: Deploy the gateway**

On `lts1`:

```bash
docker compose up -d --build --no-deps micromix-api
curl http://localhost:8902/v1/health
```

- [ ] **Step 7: Run live non-inference smoke tests**

Confirm the three new paths appear in `/openapi.json`. Upload and download a
small valid audio fixture. Send deliberately invalid bodies to each new route
and require HTTP 422 without creating jobs. This validates routing and deployed
models without claiming the GPU.

- [ ] **Step 8: Run one approved short inference smoke**

Submit one 10-second, one-variation reference generation using a disposable
fixture. Poll to a terminal state, download the output, verify nonzero size and
hash metadata, and leave listening quality for the user.

- [ ] **Step 9: Verify final synchronization**

Require local, GitHub, and `lts1` `main` hashes to match and preserve the
untracked root `AGENTS.md`.
