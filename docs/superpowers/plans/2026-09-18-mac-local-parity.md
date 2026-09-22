# Mac-local parity implementation plan

**Status:** Complete. Merged to `main` on 2026-09-18 (PR #2, commit `b578046`).
All five tasks landed: durable SQLite runtime, local model workers, native
parity workflows (including Vocal Swap and Stem Split), API integration, and
verification. Remaining gates are manual: real weights, listening, visual and
Logic acceptance per `docs/evaluations/local-migration.md`.

> **For agentic workers:** Use subagent-driven-development for independent implementation domains, then integrate and review the whole branch. Do not run heavy inference or desktop automation.

**Goal:** Restore the audited server features locally and fix broken local adapters.
**Architecture:** SQLite authority, disposable model subprocesses, loopback API, native SwiftUI workflows.
**Tech Stack:** Python 3.12, SQLite, FastAPI, MLX/PyTorch MPS, Swift 6.
**Spec:** docs/superpowers/specs/2026-09-18-mac-local-parity.md

## Constraints

All development and inference run on the Mac. Keep private data ignored. No models are downloaded or run during automated testing. Preserve existing installed app and running sidecar until a coordinated manual update.

## Task 1 — durable runtime

Files: local_inference/runtime.py, tests/test_runtime.py. Implement Runtime(root, command_factory), persistent assets/jobs and serial subprocess execution. Job public fields match /v1/jobs; worker manifest contains operation, parameters, input paths and output_dir. Worker writes result.json containing outputs [{path,filename,media_type,name}] and optional provenance. Tests: create/reopen SQLite; cancel queued/running child; failure after cancellation; fixed-seed interrupted recovery; atomic output registration; pruning preserves active assets.

## Task 2 — local model workers

Files: local_inference/worker.py, local_inference/engines.py, tests/test_engines.py, scripts/setup-local-models.sh, services/local-inference model setup documentation. Verify official pinned APIs. Implement worker manifest adapters for ACE-Step, MuScriptor, MLX-RVC, SAM-Audio and optional MiniMax. Regression tests: actual source conditioning and controls; 1–4 deterministic output seeds; target voice/index loaded; STTOutput text extraction; transcription instrument/tempo forwarding. No inference in tests.

## Task 3 — native parity workflows

Files: MacOS/sources and focused native tests. Restore supported generation/Reimagine wire controls and UI. Add Vocal Swap and Stem Split through shared typed API, view models, recovery and Library. Validate missing voice/source/description, cancellations and exact routes. Run headless Swift tests. No visual automation.

## Task 4 — API integration

Files: local_inference/main.py, tests/test_contract.py and API tests. Replace in-memory job authority with Runtime. Validate requests, fixed seeds, profiles and source type. Use bounded uploads, durable metadata and lifespan dispatcher. Wire worker command/environment selection, capabilities and health. Verify with actual temporary store and fake lightweight worker.

## Task 5 — verification, review and handoff

Run backend unittest discovery and full xcodebuild tests; review combined diff. Update parity matrix and install/manual acceptance instructions with exact remaining gates. Commit narrow changes and integrate into main under existing user push/merge authorization once checks pass. Do not claim model quality or real inference acceptance from adapter tests.

## Execution ledger

- Design selected: use upstream local ACE-Step/MuScriptor instead of trying to make MiniMax/Basic Pitch expose capabilities they do not implement.
- Tasks 1–3 dispatched independently; root owns API integration and documentation.
