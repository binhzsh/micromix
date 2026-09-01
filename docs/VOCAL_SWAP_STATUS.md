# Vocal Swap Status Handoff

**Last updated:** 2026-08-31

## Product decision

Vocal Swap is a focused stem-to-voice workflow:

1. Prepare and isolate a vocal stem in Logic Pro.
2. Import that one audio stem into Micromix.
3. Choose a private target voice.
4. Receive one converted WAV stem and return to Logic.

Out of scope for this version: full-song input, stem separation, accompaniment
upload, preview/reference mixes, voice training UI, and exposed RVC controls.

## Approved design and plan

- Design: `docs/superpowers/specs/2026-08-31-phase-2-vocal-swap-stem-design.md`
- Plan: `docs/superpowers/plans/2026-08-31-phase-2-vocal-swap-stem.md`
- RVC direction was approved after inspecting Maestro on `lts1`.

Maestro findings:

- Its `main` checkout was clean and current with origin when inspected.
- Its `maestro-rvc:local` image exists and exposes `/health`, `/models`,
  `/convert`, and job polling.
- Its historical release evidence records successful RVC conversion end to end.
- Applio conversion was not validated, so Micromix should use RVC.
- Available model weights are test/smoke artifacts only. A real private target
  voice model must be placed in Micromix's ignored voice root before creative
  use can be evaluated.

Micromix will package the proven Maestro RVC implementation in its own
`vocal-swap` service. It must not make Maestro a runtime dependency.

## Repository state

Local Mac checkout:

- Branch: `main`
- Last pushed implementation commit before this handoff: `efa5672`
  (`feat(macos): navigate render alternatives`)
- Vocal Swap documentation commits:
  - `12209be` — design
  - `2556d3d` — implementation plan
  - `758160a` — select Maestro RVC

## Execution progress

The inline plan started on `lts1`, Task 1 (private worker manifest contract).

Uncommitted remote files created in `~/apps/micromix`:

- `services/vocal-swap/pyproject.toml`
- `services/vocal-swap/tests/test_manifest.py`

The first test run used the pinned disposable uv image:

```bash
cd ~/apps/micromix
docker run --rm -v "$PWD/services/vocal-swap:/app" -w /app \
  ghcr.io/astral-sh/uv:0.7.22-python3.12-bookworm \
  uv run --group dev python -m pytest tests/test_manifest.py -q
```

It did not reach a missing-production-module failure. It stopped at a syntax
error in `tests/test_manifest.py` near line 50: the second voice fixture has an
unclosed dictionary/list expression. Correct this test fixture first, then
rerun the command and confirm the expected missing-import RED state.

The disposable test environment also created ignored `.venv/` and `uv.lock`
state under `services/vocal-swap`; inspect `git status --short` before staging.

## Current blocker

Immediately after that test run, `lts1` began refusing SSH connections:

```text
ssh: connect to host 10.10.10.10 port 22: Connection refused
```

Three retries failed. Do not assume the remote checkout is clean or discard its
uncommitted scaffold. Once SSH returns, inspect it first:

```bash
ssh lts1
cd ~/apps/micromix
git status --short --branch
nl -ba services/vocal-swap/tests/test_manifest.py | sed -n '35,70p'
```

## Resume order

1. Restore SSH access to `lts1`.
2. Inspect the remote checkout and correct the manifest-test fixture.
3. Follow Task 1's red/green cycle in the implementation plan; create only
   `models.py`, `manifest.py`, and `converter.py` after the test fails for the
   intended missing implementation.
4. Commit and push Task 1 on `lts1`, then synchronize the Mac checkout with
   `git pull --ff-only` before native work.
5. Continue Tasks 2–5 on `lts1`; continue Tasks 6–7 on the Mac.
6. Do not start creative acceptance until a real private RVC target model is
   installed in Micromix's ignored voice directory.
