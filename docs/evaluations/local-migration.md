# Local migration verification — 2026-09-18

Status: automated contract checks pass; manual app and audio acceptance pending.

## Automated evidence

- `xcodebuild test -project Micromix.xcodeproj -scheme Micromix -destination
  'platform=macOS' -parallel-testing-enabled NO` from `MacOS`: 79 tests in 14
  suites pass.
- `.venv/bin/python -m unittest discover -s tests -v` from
  `services/local-inference`: 3 contract tests pass, including all four music
  submission routes, real asset upload, preset normalization and rejection of
  unsupported controls. Inference dispatch is mocked; models are never loaded.
- Regression tests first reproduced the missing `database` health decode,
  advertised preset rejection and silently accepted unsupported inputs.
- Existing local health/capability endpoints respond; this does not validate
  model output, performance or the installed app.

## Manual update and acceptance

All commands below run on the Mac. Preserve wanted outputs in Library or export
them before restarting the sidecar: in-memory job and asset indexes are lost.
Do not interrupt an active render. The source fixes are not loaded into an
already-running sidecar or an already-installed app automatically.

From the repository root, build a reviewable app:

```bash
cd MacOS
xcodegen generate
xcodebuild build -project Micromix.xcodeproj -scheme Micromix \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/micromix-local-review
cd ..
```

If using the existing LaunchAgent, restart it after preserving outputs:

```bash
launchctl kickstart -k gui/$(id -u)/com.micromix.local-inference
bash scripts/smoke-test.sh
```

Otherwise stop the manually started sidecar and run it again:

```bash
cd services/local-inference
.venv/bin/python -m local_inference.main
```

Quit any old Micromix app, then launch the review build manually:

```bash
open /tmp/micromix-local-review/Build/Products/Debug/Micromix.app
```

1. Confirm the connection indicator is available even when model status is
   `unloaded`. If a legacy `lts1` setting existed, confirm local connection.
2. Confirm Generate/Reimagine show MiniMax, seed and applicable duration/range
   controls, without unsupported variations, strength or dedicated musical
   metadata controls. Check layout and keyboard accessibility.
3. Generate one short instrumental and one vocal example in each of English
   and Vietnamese. Check prompt adherence, intelligibility and tonal meaning.
4. Run Reference and Remix with a short source. Judge the new arrangement with
   the expectation that extracted lyrics guide it; melody/voice preservation
   is not supported. Repaint a valid range and listen to its boundaries.
5. Run Transcribe, then confirm generated audio and MIDI import into Library
   and Logic. Inspect source/operation/seed/model provenance.
6. Record model revisions, runtime, peak memory, audible defects and usefulness.
   Report outcomes before declaring the migration accepted.

Job persistence/restart recovery, vocal workflow UI and broader model-quality
validation remain open. The historic server branch is not needed for these checks.
