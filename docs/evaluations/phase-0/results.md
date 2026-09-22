# Micromix Phase 0 Baseline Results — Local Runtime

**Gate:** PENDING MANUAL EVALUATION (local Mac runtime)

The previous contents of this file described the retired `lts1`/Docker
deployment. That baseline is preserved in git history (commit `763fb8cd`,
2026-08-31) and no longer applies. This document is the live scorecard for the
Mac-local runtime defined by `docs/evaluations/local-migration.md`.

## Environment

Captured 2026-09-22 on the development Mac (America/Los_Angeles).

| Component | Identity |
| --- | --- |
| Repo commit under test | `4cf200df32c27f62d68eee06c72bdcce7f8394b9` (`docs: reconcile plan statuses after local migration`) |
| Runtime | native macOS app + local FastAPI sidecar at `http://127.0.0.1:8902` (LaunchAgent `com.micromix.local-inference`) |
| Sidecar commit revision pins | ACE `ca1e85fe`, MuScriptor `7f213afe`, MLX-Audio `40b27a21`, MLX-RVC `f2663353` (from `local_inference/engines.py`) |
| ACE checkpoints | `acestep-v15-xl-turbo` (8 steps), `acestep-v15-xl-sft` (50 steps) — weights present in `~/.cache/huggingface/hub` and `~/.cache/ace-step/diffusers` |
| MiniMax | `mlx-community/MiniMax-Music3-mxfp8` (text-only generation, 30 steps) — weights present |
| SAM-Audio stem split | `mlx-community/sam-audio-large` — weights present |
| MuScriptor | `muscriptor 0.3.0` in isolated `.venv-muscriptor`; gated license access required for transcription (verify before step 4) |
| MLX-RVC voice models | `base` only (`services/local-inference/data/voice-models/base.safetensors`); private RVC voice(s) must be imported before step 5 |
| ACE source revision | verify at setup: `git -C <ace checkout> rev-parse HEAD` (pin expected to match `ca1e85fe`) |
| Python envs | `.venv-ace`, `.venv-muscriptor`, `.venv-mlx` (isolated per engine) |

Fill in before recording results:

- Sidecar process uptime / restart count at eval start: ______
- Mac unified memory available at eval start: ______
- MuScriptor license status (working / expired): ______
- Private voice model(s) imported (name + SHA-256 revision shown by app): ______

## Automated evidence (local runtime)

| Suite | Method | Result |
| --- | --- | --- |
| Sidecar Python | `cd services/local-inference && .venv/bin/python -m unittest discover -s tests` | **39 pass (re-verified 2026-09-22 at `4cf200df`)** — API contracts, controls, private voice revisions, adapter forwarding, durable storage, atomic publication, cancellation, recovery, pre-commit crashes, retention, streaming uploads |
| macOS Swift | `xcodegen generate`, then `xcodebuild test -project Micromix.xcodeproj -scheme Micromix -destination 'platform=macOS'` | 80 pass in 14 suites (2026-09-18); DeviceWindowTests excluded (visual rendering). Model calls mocked in adapter tests; runtime tests use real lightweight subprocesses. No weights or inference run. |
| Independent re-review | runtime/API re-review of the local migration | no blocking defects found |

Re-run the Swift suite before the manual gate if native code changes since 2026-09-18.

## Manual scorecard

Corpus: `evaluations/private/corpus-manifest.json` (private, git-ignored).
Current cases and their sources:

| Case | Category | Source | Duration | Vocals | Operations |
| --- | --- | --- | --- | --- | --- |
| Case | Category | Source | Duration | Vocals | Operations |
| --- | --- | --- | --- | --- | --- |
| `clean-studio` | clean_studio | `sources/case-a.m4a` (284 s) | medium | vi, polyphonic | reference, remix, repaint, transcribe |
| `expressive-vocal` | expressive_vocal | `sources/case-a.m4a` (284 s) | medium | vi, polyphonic | reference, repaint |
| `dense-mix` | dense_mastered_mix | `sources/case-b.m4a` (301 s) | medium | vi, polyphonic | reference, remix, repaint, transcribe |
| `long-source` | long_source | `sources/case-c.m4a` (653 s) | long | vi, polyphonic | reference, remix, repaint, transcribe |

All sources are 2 ch / 48 kHz ALAC-in-M4A. Transcribe format coverage
(WAV/MP3/M4A): derive WAV and MP3 variants from these files before step 4 if
the app does not accept M4A directly for that operation.

Coverage gaps vs the Phase 0 corpus requirement (roadmap): `english_vocal`,
`live_or_noisy`, `instrumental_only`. Note in findings if a gap materially
limits what this evaluation can conclude; do not block on it.

Scoring: **Usefulness** and **Source preservation** are `1-5`; everything else
is pass/fail or free text. A score of 1-2 on any row is release-blocking until
explained as an accepted limitation.

### 1. Workspaces, controls, connection

| Check | Result | Notes |
| --- | --- | --- |
| All seven workspaces open without error | P/F | |
| Connection status shows sidecar ready | P/F | |
| Keyboard access through each workspace | P/F | |

### 2. Generate (Turbo + Quality, EN/VI, fixed seeds, 4 variations)

Use the same prompt and seed per language so results are comparable. Record
the seed(s) used: ______

| Check | EN result | VI result | Notes |
| --- | --- | --- | --- |
| Metadata intent honored (bpm/key/instrument) | 1-5 | 1-5 | |
| Intelligibility of any vocals / coherence of instrumental | 1-5 | 1-5 | |
| Vietnamese tones correct (VI column only) | — | P/F | |
| Four variations produced, distinct but on-prompt | P/F | P/F | |
| Reproducible with same seed (re-run one variation) | P/F | P/F | |
| Runtime per variation (Turbo / Quality) | ______ s | ______ s | |

### 3. Reimagine — reference, cover, repaint

| Case | Check | Result | Notes |
| --- | --- | --- | --- |
| `clean-studio` | Reference influence visible without copying source | 1-5 | |
| `dense-mix` | Cover strength (style shift vs source fidelity) | 1-5 | |
| `expressive-vocal` | Repaint on valid interval: surrounding audio preserved, boundaries clean | P/F + 1-5 | interval used: ______ |

### 4. Transcribe + Logic MIDI import

MuScriptor license must be confirmed working before this section.

| Case | Check | Result | Notes |
| --- | --- | --- | --- |
| `clean-studio` (m4a) | Tracks present, instruments sensible with filter on/off | 1-5 | |
| `dense-mix` | Polyphonic separation quality | 1-5 | |
| `long-source` | Long-file completion, no truncation | P/F | runtime ______ s |
| Any case | Tempo detection: grid aligned (note: strict mode may reject unstable beats) | P/F | bpm detected: ______ |
| Any case | Imported into Logic: tracks/grid correct | P/F | Logic version ______ |

Format coverage: WAV / MP3 / M4A — mark which were exercised: ______

### 5. Vocal Swap + Stem Split

Requires an imported private voice model (revision recorded above).

| Check | Result | Notes |
| --- | --- | --- |
| Convert prepared vocal with two private voices (or `base` if only one available) | identity 1-5 / intelligibility 1-5 | voices: ______ |
| Pitch offsets applied as requested | P/F | offsets: ______ |
| Optional index + index_rate path works | P/F | |
| Provenance shows engine, revision, voice model revision | P/F | |
| Stem split (SAM-Audio): target and residual both usable | 1-5 | description used: ______ |

### 6. Cancellation, restart recovery, Library save

| Check | Result | Notes |
| --- | --- | --- |
| Cancel a queued job → terminal state consistent | P/F | |
| Cancel a running job → no orphaned output published | P/F | |
| Restart sidecar mid-job → durable reattachment, inputs retained | P/F | job id: ______ |
| Save selected results to Library | P/F | |

### 7. Resource and defect log

- Peak unified memory during heaviest job (Quality generation / long transcribe): ______
- Defects found (severity: release-blocking / cosmetic):
  1. ______
  2. ______

## Verdict

| Item | Status |
| --- | --- |
| Automated tests (local) | PASS (re-verified: ______) |
| Sidecar ↔ app API contract | P/F |
| All creative operations have a recorded manual result | P/F |
| Release-blocking findings open | count: ______ |
| **Phase 0 gate** | PENDING / PASS / FAIL — date: ______ |

Automatic full-song vocal preparation/mixing, Vocal Improve, Mashup and
Complete are future product work (roadmap Phase 2+), not part of this gate.
