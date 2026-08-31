# Micromix Phase 0 Baseline Results

**Gate:** PENDING MANUAL EVALUATION

**Deployed release commit:** `763fb8cd3b59e8422405c6511f797fd78b23f3d5`

**Automated verification:** PASS

**Manual listening and Logic import:** PENDING

**Open release-blocking findings:** 0 known; manual evaluation not yet complete

## Environment

Captured on 2026-08-31 in America/Los_Angeles.

| Component | Identity |
| --- | --- |
| Mac `main` | `763fb8cd3b59e8422405c6511f797fd78b23f3d5` |
| GitHub `origin/main` at deployment | `763fb8cd3b59e8422405c6511f797fd78b23f3d5` |
| `lts1` checkout | `763fb8cd3b59e8422405c6511f797fd78b23f3d5` |
| Micromix API image | `sha256:46d4b9011a3669bc3e4b550f45c49873c6e8481ec526d67e17dfbc4105c1f77e` |
| ACE-Step image | `sha256:b874a12201949767bd3a36d5c623fdf4d1af2291e0ecb9b775fa437efd2b965c` |
| MuScriptor image | `sha256:2af17de70fa47615fa7739454f91ef8310e692f1b049fdaa6398ec782c80e204` |
| ACE checkpoints | `acestep-v15-xl-turbo`, `acestep-v15-xl-sft` |
| ACE inference steps | Turbo 8; Quality 50 |
| ACE source revision | `dce621408bee8c31b4fcf4811682eb9359e1bc94` |
| MuScriptor | `0.3.0`, Medium profile |

## Automated tests

| Suite | Method | Result |
| --- | --- | --- |
| macOS Swift | `xcodegen generate`, then full `xcodebuild test` | PASS — 72 tests in 14 suites |
| Micromix API | frozen `uv:0.7.22-python3.12-bookworm` container | PASS — 78 tests |
| MuScriptor worker | frozen `uv:0.9.30-python3.12-bookworm` container | PASS — 7 tests |
| ACE supervisor | isolated `uv` container with pinned test dependencies | PASS — 4 tests |

The server host does not install `uv` globally. Tests used disposable containers
with the repository mounted read-only and project environments under `/tmp`.
The MuScriptor and ACE runs emitted non-failing pytest cache warnings because
the repository mount was read-only. MuScriptor also emitted the upstream
Starlette `httpx` deprecation warning.

## Deployment health

`docker compose up -d --build` rebuilt and recreated all three services from the
deployed release commit.

After application startup:

- gateway service: `micromix-api`, status `ok`;
- database: `ready`;
- GPU router: `ready`, 24,113 MiB free before inference;
- ACE-Step worker: `cold`;
- MuScriptor worker: `cold`;
- generation presets: Turbo and Quality; and
- transcription instruments: 36.

The first probe was issued approximately one second after Compose reported the
API container as running and received a connection reset while Uvicorn was
still starting. Container inspection showed no restart or crash; logs then
reported application startup complete. The unchanged cold smoke passed after
readiness. Disposition: `documented-limitation` for operational startup timing;
no application defect was observed.

## Required API routes

The deployed OpenAPI document includes:

```text
/v1/assets
/v1/assets/{asset_id}
/v1/capabilities
/v1/health
/v1/jobs
/v1/jobs/generation
/v1/jobs/reference-generation
/v1/jobs/remix
/v1/jobs/repaint
/v1/jobs/transcription
/v1/jobs/{job_id}
/v1/jobs/{job_id}/cancel
```

## Real cold-generation smoke

| Field | Value |
| --- | --- |
| Job ID | `b4d662de274f4c43ba8d1f9db7f508f5` |
| Upstream ID | `3e84146e-4ea3-426b-8b9a-a439e56cbdfa` |
| Operation | text generation |
| Prompt | `warm lo-fi drums and electric piano, instrumental` |
| Preset | Turbo |
| Requested duration | 10 seconds |
| Effective seed | `3189942306` |
| Variations | 1 |
| Initial worker state | cold |
| Created | `2026-08-31T21:48:31.282191Z` |
| Succeeded | `2026-08-31T21:51:30.250763Z` |
| End-to-end duration | approximately 179 seconds |
| Terminal state | succeeded |
| Output media | stereo WAV, 48 kHz, 10.000 seconds |
| Asset ID | `48c37ebee5b6438384adba01311d8ba7` |
| Size | 1,920,078 bytes |
| SHA-256 | `56c3cb946a28a0295822e486311aacf0e891f55bf6deac205b68a9fdd65900f9` |
| Download verification | size and SHA-256 match durable asset metadata |
| Worker state after completion | cold; GPU released |
| Peak VRAM | unavailable from current telemetry |

This smoke verifies submission, GPU acquisition, cold model start, polling,
inference, durable output metadata, download, checksum, and GPU release. Audio
quality remains part of the manual corpus gate.

## Manual evaluation

Manual scorecards are pending for Generate, Reference, Remix/Cover, Repaint,
Transcribe, real-job reattachment, provenance, and Logic import. Phase 0 cannot
pass until these checks are completed and every release-blocking finding is
resolved.
