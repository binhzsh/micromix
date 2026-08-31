# Phase 1A Bilingual Generation Controls Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add reproducible Generate controls and English/Vietnamese vocal intent
while retaining simple native UI and durable provenance.

**Architecture:** A shared native `GenerationOptions` value crosses the
Generate service seams and API serializer. FastAPI validates `en`/`vi`, stores
the language in the existing job parameters, and ACE receives it only for text
and reference operations. SwiftUI exposes a concise language picker and a
collapsed musical-options group.

**Tech Stack:** Swift 6, SwiftUI, Testing, Python 3.12, FastAPI/Pydantic,
pytest, Docker Compose, ACE-Step 1.5.

**Spec:** `docs/superpowers/specs/2026-08-31-phase-1a-bilingual-generation-controls-design.md`

## Global Constraints

- Backend code and Docker deployment changes run only on `lts1`.
- Native app code and `xcodebuild` tests run on the Mac.
- Keep WAV as the only production output format.
- Allow only Auto, English (`en`), and Vietnamese (`vi`) language intent.
- Do not expose low-level model controls.
- Follow red-green-refactor for every production behavior.

---

### Task 1: Add validated language intent to the gateway

**Files:**

- Modify: `services/micromix-api/micromix_api/models.py`
- Test: `services/micromix-api/tests/test_api.py`

- [x] Write failing pytest cases asserting `vocal_language="en"` and `"vi"`
      are accepted and `"fr"` returns HTTP 422.
- [x] Run the focused tests on `lts1` with the frozen uv container and confirm
      they fail because `vocal_language` is rejected.
- [x] Add optional `Literal["en", "vi"]` to `GenerationControls`.
- [x] Re-run focused tests and the full API suite.
- [x] Commit: `feat(api): validate bilingual generation language`.

### Task 2: Forward language only to supported ACE task types

**Files:**

- Modify: `services/micromix-api/micromix_api/adapters.py`
- Test: `services/micromix-api/tests/test_adapters.py`

- [x] Write failing adapter tests for `vocal_language` on text and reference
      payloads, and absence on Remix/Repaint payloads.
- [x] Run the focused adapter tests and confirm the expected missing-key
      failure.
- [x] Add the minimal `operation in {"text", "reference"}` payload mapping.
- [x] Re-run focused and full API tests.
- [x] Commit: `feat(api): forward bilingual ACE language intent`.

### Task 3: Add native generation option types and service seams

**Files:**

- Modify: `MacOS/sources/Core/Models.swift`
- Modify: `MacOS/sources/Core/ServiceProtocols.swift`
- Modify: `MacOS/Tests/Generate/GenerateViewModelTests.swift`

- [x] Write failing Swift tests that pass `GenerationOptions` through fake
      durable and legacy generation services.
- [x] Run the focused Generate ViewModel tests and confirm compilation fails
      because the type and protocol argument do not exist.
- [x] Add `VocalLanguage` and `GenerationOptions`, then extend both generation
      protocols with the defaultable options argument.
- [x] Update fakes and rerun focused tests.
- [x] Commit: `feat(macos): model bilingual generation options`.

### Task 4: Serialize Generate and Reference options precisely

**Files:**

- Modify: `MacOS/sources/Core/MicromixAPI.swift`
- Modify: `MacOS/sources/Core/Models.swift`
- Test: `MacOS/Tests/Core/MicromixAPITests.swift`

- [x] Write failing tests for a Vietnamese Generate body containing seed,
      variations, BPM, key, time signature, and `vocal_language: "vi"`; write
      a second test proving Auto omits the language key.
- [x] Write a failing Reference test proving Vietnamese language serializes only
      on the reference route.
- [x] Run focused API tests and confirm failure.
- [x] Implement `GenerationOptions` body mapping, extend
      `ReimagineRequest.reference`, and omit unset values.
- [x] Re-run focused API tests and the full macOS suite.
- [x] Commit: `feat(macos): serialize bilingual generation controls`.

### Task 5: Capture immutable options in Generate lifecycle

**Files:**

- Modify: `MacOS/sources/Generate/GenerateViewModel.swift`
- Test: `MacOS/Tests/Generate/GenerateViewModelTests.swift`

- [ ] Write a failing test that changes view-model controls after `start()` and
      proves the submitted durable request retains the original options.
- [ ] Run the focused test and confirm failure.
- [x] Add published option fields, bounded local validation, and immutable
      capture before `JobRunner.start`.
- [x] Re-run focused Generate tests and the full macOS suite.
- [x] Commit: `feat(macos): retain generation option provenance`.

### Task 6: Expose concise Generate and Reference controls

**Files:**

- Modify: `MacOS/sources/Generate/GenerateScreen.swift`
- Modify: `MacOS/sources/Reimagine/ReimagineViewModel.swift`
- Modify: `MacOS/sources/Reimagine/ReimagineScreen.swift`
- Test: `MacOS/Tests/App/DeviceWindowTests.swift`
- Test: `MacOS/Tests/Reimagine/ReimagineViewModelTests.swift`

- [ ] Write failing layout and Reference-request tests for the language picker,
      musical-options disclosure, and no language key on Remix/Repaint.
- [ ] Run focused tests and confirm the new UI/state is absent.
- [x] Add Auto/English/Vietnamese controls, compact bounded option inputs, and
      Reference-only language state.
- [x] Re-run focused tests and the full macOS suite.
- [x] Commit: `feat(macos): add bilingual creative controls`.

### Task 7: Activate Phase 1 and deploy the server contract

**Files:**

- Modify: `docs/MICROMIX_ROADMAP.md`
- Modify: `docs/superpowers/plans/2026-08-31-phase-1a-bilingual-generation-controls.md`

- [ ] Mark Phase 1 active and note Phase 0 manual evaluation as a pre-release
      gate rather than a feature-development blocker.
- [ ] Run all local and server tests, merge the implementation branch to main,
      push, fast-forward `lts1`, and run `docker compose up -d --build`.
- [ ] Verify `/v1/health`, `/v1/capabilities`, one validation request for `vi`,
      and one rejection for an unsupported language code.
- [ ] Record deployment evidence and commit the phase checkpoint.
