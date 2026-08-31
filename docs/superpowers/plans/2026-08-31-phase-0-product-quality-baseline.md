# Phase 0 Product-Quality Baseline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Synchronize the Mac and `lts1`, establish a reproducible private audio
evaluation process, and record automated and manual baseline evidence for every
currently shipped Micromix operation.

**Architecture:** The repository stores evaluation instructions, an anonymized
corpus manifest, scorecard templates, and non-media results. Private source and
generated audio live only under ignored `evaluations/private/`. The Mac remains
the authority for native testing and Logic import; `lts1` remains the authority
for backend tests, Compose deployment, model revisions, and inference jobs.

**Tech Stack:** Git, Docker Compose, FastAPI, pytest, Swift Testing,
`xcodebuild`, curl, JSON, Markdown, ACE-Step 1.5, MuScriptor 0.3.0.

**Spec:** `docs/MICROMIX_ROADMAP.md` — Phase 0

## Global Constraints

- Do not commit private audio, generated media, `.env`, model weights, caches,
  or personally identifying corpus descriptions.
- Perform backend, inference-engine, and Docker Compose work only on `lts1` in
  `~/apps/micromix`.
- Perform native tests and Logic import review on the Mac.
- Never force-push, reset, or overwrite a dirty checkout. Both checkouts must be
  clean before synchronization.
- Do not automate the active desktop. The user performs listening and Logic
  import checks manually.
- Do not add Phase 1 features while collecting this baseline.
- Record exact commit IDs and model/service revisions with every result set.

## File map

- Modify: `.gitignore` — exclude private evaluation audio and generated output.
- Create: `docs/evaluations/phase-0/README.md` — evaluation procedure and
  command sequence.
- Create: `docs/evaluations/phase-0/corpus-manifest.example.json` — committed,
  anonymized corpus schema.
- Create: `docs/evaluations/phase-0/scorecard.md` — per-output manual rating
  rubric.
- Create: `docs/evaluations/phase-0/results.md` — committed baseline evidence and
  phase gate.
- Modify: `docs/MICROMIX_ROADMAP.md` — mark Phase 0 active and later complete.

---

### Task 1: Synchronize and verify the two repository checkouts

**Files:**

- Modify: `docs/MICROMIX_ROADMAP.md`

**Interfaces:**

- Consumes: pushed `origin/main` at the approved roadmap commit.
- Produces: clean Mac and `lts1` checkouts at the same exact commit, with the
  live Compose stack rebuilt from that commit.

- [x] **Step 1: Verify the Mac checkout is clean and pushed**

Run:

```bash
cd /Users/binh/Projects/micromix
git status --short --branch
git rev-parse HEAD
git rev-parse origin/main
```

Expected: no short-status entries and identical local/origin commit IDs.

- [x] **Step 2: Inspect the server checkout before changing it**

Run:

```bash
ssh lts1 'cd ~/apps/micromix && git status --short --branch && git remote -v && git rev-parse HEAD'
```

Expected: `main`, no local modifications, and the same GitHub repository.

- [x] **Step 3: Fast-forward the server checkout**

Run:

```bash
ssh lts1 'cd ~/apps/micromix && git fetch origin && git pull --ff-only origin main && git rev-parse HEAD'
```

Expected: the returned commit matches the Mac's `origin/main`.

- [x] **Step 4: Run backend unit tests on the server**

Run:

```bash
ssh lts1 'cd ~/apps/micromix/services/micromix-api && uv run pytest -q'
ssh lts1 'cd ~/apps/micromix/services/muscriptor-worker && uv run pytest -q'
ssh lts1 'cd ~/apps/micromix && python3 -m pytest services/ace-step/tests -q'
```

Expected: every suite passes. If the ACE supervisor environment does not have
pytest available at the repository root, run its documented container or venv
test command and record the exact replacement in `results.md`.

- [x] **Step 5: Rebuild and verify the deployed stack**

Run:

```bash
ssh lts1 'cd ~/apps/micromix && docker compose up -d --build'
ssh lts1 'cd ~/apps/micromix && docker compose ps'
ssh lts1 'cd ~/apps/micromix && ./scripts/smoke-test.sh'
```

Expected: all three services are running; `/v1/health` reports `ok`; the cold
smoke prints capabilities without loading a GPU worker.

- [x] **Step 6: Run the full native test suite on the Mac**

Run:

```bash
cd /Users/binh/Projects/micromix/MacOS
xcodegen generate
xcodebuild test -project Micromix.xcodeproj -scheme Micromix -destination 'platform=macOS'
```

Expected: `** TEST SUCCEEDED **` and all Swift Testing tests pass.

- [x] **Step 7: Mark Phase 0 active**

In `docs/MICROMIX_ROADMAP.md`, change only the Phase 0 heading to:

```markdown
## Phase 0 — Product-quality baseline `[~]`
```

- [x] **Step 8: Commit the synchronization milestone**

```bash
git add docs/MICROMIX_ROADMAP.md
git commit -m "docs: start Phase 0 quality baseline"
git push origin main
```

### Task 2: Create the private evaluation workspace and corpus contract

**Files:**

- Modify: `.gitignore`
- Create: `docs/evaluations/phase-0/README.md`
- Create: `docs/evaluations/phase-0/corpus-manifest.example.json`

**Interfaces:**

- Consumes: user-owned audio placed under `evaluations/private/sources/`.
- Produces: stable anonymized case IDs used by every scorecard and result entry.

- [x] **Step 1: Add private evaluation paths to `.gitignore`**

Append:

```gitignore

# Private model-evaluation inputs and generated media
evaluations/private/
```

- [x] **Step 2: Create the corpus manifest schema**

Create `docs/evaluations/phase-0/corpus-manifest.example.json` with:

```json
{
  "schema_version": 1,
  "cases": [
    {
      "id": "clean-studio",
      "category": "clean_studio",
      "source_path": "evaluations/private/sources/clean-studio.wav",
      "duration_class": "medium",
      "has_vocals": true,
      "is_polyphonic": true,
      "operations": ["reference", "remix", "repaint", "transcribe"]
    },
    {
      "id": "dense-mix",
      "category": "dense_mastered_mix",
      "source_path": "evaluations/private/sources/dense-mix.wav",
      "duration_class": "medium",
      "has_vocals": true,
      "is_polyphonic": true,
      "operations": ["reference", "remix", "repaint", "transcribe"]
    },
    {
      "id": "live-noisy",
      "category": "live_or_noisy",
      "source_path": "evaluations/private/sources/live-noisy.wav",
      "duration_class": "medium",
      "has_vocals": true,
      "is_polyphonic": true,
      "operations": ["reference", "remix", "repaint", "transcribe"]
    },
    {
      "id": "expressive-vocal",
      "category": "expressive_vocal",
      "source_path": "evaluations/private/sources/expressive-vocal.wav",
      "duration_class": "short",
      "has_vocals": true,
      "is_polyphonic": false,
      "operations": ["reference", "repaint"]
    },
    {
      "id": "instrumental",
      "category": "instrumental",
      "source_path": "evaluations/private/sources/instrumental.wav",
      "duration_class": "medium",
      "has_vocals": false,
      "is_polyphonic": true,
      "operations": ["reference", "remix", "repaint", "transcribe"]
    },
    {
      "id": "long-source",
      "category": "long_source",
      "source_path": "evaluations/private/sources/long-source.wav",
      "duration_class": "long",
      "has_vocals": true,
      "is_polyphonic": true,
      "operations": ["reference", "remix", "repaint", "transcribe"]
    }
  ]
}
```

- [x] **Step 3: Write the evaluation procedure**

Create `docs/evaluations/phase-0/README.md` specifying:

- Copy the example manifest to ignored
  `evaluations/private/corpus-manifest.json`.
- Replace only `source_path` values and case applicability; keep anonymized IDs.
- Store generated audio/MIDI under a directory such as
  `evaluations/private/results/ed9c1eb/reference/clean-studio/`, replacing the
  example commit, operation, and case with the values for the run.
- Use the same prompt, seed, preset, and variation count when comparing runs.
- Never commit input or output media.
- Record failed jobs as results rather than silently rerunning them.
- Run Logic import and listening checks manually.

- [x] **Step 4: Verify ignored media cannot be staged accidentally**

Run:

```bash
mkdir -p evaluations/private/sources
touch evaluations/private/sources/ignore-check.wav
git status --short --ignored evaluations/private/sources/ignore-check.wav
```

Expected: `!! evaluations/private/` or its child path.

- [x] **Step 5: Commit the workspace contract**

```bash
git add .gitignore docs/evaluations/phase-0/README.md docs/evaluations/phase-0/corpus-manifest.example.json
git commit -m "docs: define private audio evaluation corpus"
git push origin main
```

### Task 3: Define the scorecard and acceptance thresholds

**Files:**

- Create: `docs/evaluations/phase-0/scorecard.md`

**Interfaces:**

- Consumes: one operation output and its corresponding source.
- Produces: a comparable rating record with an explicit keep/fix/stop decision.

- [x] **Step 1: Create the scorecard rubric**

Create `docs/evaluations/phase-0/scorecard.md` with a 1–5 anchored scale for:

- creative usefulness;
- source/intent preservation;
- musical coherence;
- audible artifacts;
- edit burden before use in Logic;
- transcription note/timing/instrument accuracy when applicable; and
- operational reliability.

Define `1` as unusable, `3` as useful after material correction, and `5` as
immediately useful with only normal finishing work. Lower artifact scores must
mean worse artifacts so every dimension has the same higher-is-better direction.

- [x] **Step 2: Define the operation pass gate**

Record these exact rules in the scorecard:

```text
An operation passes the baseline when:
- every tested job reaches a terminal state and every successful asset imports;
- no checksum, reattachment, or provenance failure occurs;
- median creative usefulness is at least 3;
- median edit-burden score is at least 3; and
- no case receives an artifact score of 1 without a documented limitation or fix.
```

- [x] **Step 3: Add runtime and environment fields**

Require commit ID, service/model revision, preset, seed, input duration, output
duration, wall time, job state, worker cold/warm state, and peak VRAM when
available.

- [x] **Step 4: Commit the scorecard**

```bash
git add docs/evaluations/phase-0/scorecard.md
git commit -m "docs: define Micromix quality scorecard"
git push origin main
```

### Task 4: Capture automated baseline evidence

**Files:**

- Create: `docs/evaluations/phase-0/results.md`

**Interfaces:**

- Consumes: synchronized release commit and passing automated checks.
- Produces: dated evidence for build, tests, deployment, health, capabilities,
  routes, and pinned models.

- [x] **Step 1: Record repository and deployment identity**

Capture the exact output of:

```bash
git rev-parse HEAD
ssh lts1 'cd ~/apps/micromix && git rev-parse HEAD'
ssh lts1 'cd ~/apps/micromix && docker compose images'
```

Summarize commit and image IDs in `results.md`; do not paste noisy full logs.

- [x] **Step 2: Record API health, capabilities, and route surface**

Run:

```bash
ssh lts1 'curl -fsS http://localhost:8902/v1/health'
ssh lts1 'curl -fsS http://localhost:8902/v1/capabilities'
ssh lts1 'curl -fsS http://localhost:8902/openapi.json' \
  | python3 -c 'import json,sys; print("\n".join(sorted(json.load(sys.stdin)["paths"])))'
```

Record worker cold state, GPU availability, generation presets, instrument
count, and required routes.

- [x] **Step 3: Record automated test totals**

Add the pass/fail result and test count for:

- Micromix API tests;
- MuScriptor worker tests;
- ACE supervisor tests; and
- macOS Swift tests.

- [x] **Step 4: Run a real short generation smoke**

Run on `lts1`:

```bash
ssh lts1 'cd ~/apps/micromix && RUN_GENERATION=1 ./scripts/smoke-test.sh'
```

Expected: the job succeeds and `/tmp/micromix-smoke.wav` is created on `lts1`.
Record wall time, terminal job state, output media type, and asset size. Do not
commit the WAV.

- [x] **Step 5: Commit automated evidence**

```bash
git add docs/evaluations/phase-0/results.md
git commit -m "docs: record Phase 0 automated baseline"
git push origin main
```

### Task 5: Run the manual creative-operation evaluation

**Files:**

- Modify: `docs/evaluations/phase-0/results.md`

**Interfaces:**

- Consumes: private corpus, scorecard, deployed app, and live `lts1` stack.
- Produces: one scored record per applicable operation/case and a list of
  release-blocking defects.

- [ ] **Step 1: Ask the user to populate the private corpus**

Required categories are clean studio, dense mastered mix, live/noisy,
expressive vocal, instrumental/polyphonic, and long source. A single source may
cover multiple categories if the manifest records that choice.

- [ ] **Step 2: Evaluate Generate**

Create at least one Turbo and one Quality result using the same musical
direction. Record seeds, runtime, usefulness, coherence, artifacts, and Logic
import result.

- [ ] **Step 3: Evaluate Reference generation**

Run each applicable case with a fixed prompt and seed. Score whether the output
is recognizably guided by the source while remaining useful.

- [ ] **Step 4: Evaluate Remix/Cover**

Run each applicable case with a fixed transformation direction and source
strength. Score preservation, transformation success, coherence, artifacts,
and edit burden.

- [ ] **Step 5: Evaluate Repaint**

Choose a musically meaningful 6–12 second range in each applicable case. Score
replacement quality, boundary continuity, source preservation outside the
range, and edit burden.

- [ ] **Step 6: Evaluate Transcribe**

Run every applicable polyphonic/multi-instrument case. Import the MIDI into
Logic, audition it, and score notes, timing, instrument assignment, and
correction burden.

- [ ] **Step 7: Verify recovery and provenance once with a real job**

Quit and relaunch Micromix while one generation job is pending. Confirm the job
reattaches, every output imports once, checksums match, and the Library shows
source, operation, parameters, job ID, and output position.

- [ ] **Step 8: Classify findings**

For each issue, record exactly one disposition:

- `release-blocking` — prevents trustworthy use and must be fixed in Phase 0;
- `phase-1-candidate` — workflow improvement that does not invalidate baseline;
- `documented-limitation` — model behavior with a safe workaround; or
- `no-action` — subjective preference or non-recurring artifact.

### Task 6: Close the Phase 0 gate

**Files:**

- Modify: `docs/evaluations/phase-0/results.md`
- Modify: `docs/MICROMIX_ROADMAP.md`

**Interfaces:**

- Consumes: automated evidence, completed manual scorecards, and resolved
  release-blocking defects.
- Produces: explicit Phase 0 pass/stop decision and authorization to design
  Phase 1.

- [ ] **Step 1: Resolve every release-blocking finding**

Each fix receives its own bounded design approval, failing test, implementation,
verification, and conventional commit. Re-run the affected corpus cases after
the fix.

- [ ] **Step 2: Write the gate decision**

At the top of `results.md`, record the actual 40-character output of
`git rev-parse HEAD` in a `Release commit` field. Add these four additional
fields with their observed values:

```markdown
Gate: PASS or FAIL
Automated verification: PASS or FAIL
Manual listening and Logic import: PASS or FAIL
Open release-blocking findings: a numeric count
```

Use `FAIL` rather than `PASS` if any condition is unmet; do not leave example
values in a committed result.

- [ ] **Step 3: Mark Phase 0 complete**

Change the Phase 0 heading in `docs/MICROMIX_ROADMAP.md` to:

```markdown
## Phase 0 — Product-quality baseline `[x]`
```

Check each completed Phase 0 outcome and leave any failed outcome unchecked with
its disposition linked from `results.md`.

- [ ] **Step 4: Run final verification**

Run:

```bash
git diff --check
cd /Users/binh/Projects/micromix/MacOS
xcodebuild test -project Micromix.xcodeproj -scheme Micromix -destination 'platform=macOS'
ssh lts1 'cd ~/apps/micromix/services/micromix-api && uv run pytest -q'
ssh lts1 'cd ~/apps/micromix && ./scripts/smoke-test.sh'
```

Expected: no diff errors, all tests pass, and the deployed gateway is healthy.

- [ ] **Step 5: Commit and push the completed gate**

```bash
git add docs/MICROMIX_ROADMAP.md docs/evaluations/phase-0/results.md
git commit -m "docs: complete Phase 0 quality baseline"
git push origin main
```

- [ ] **Step 6: Begin Phase 1 design only after the gate passes**

Use the Phase 0 evidence to choose the smallest Phase 1 scope. Do not carry a
failed model operation forward merely because the upstream model advertises it.
