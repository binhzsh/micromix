# Micromix — next steps

Updated 2026-11-06. This is an actionable follow-up to the product direction and phase gates in [the roadmap](docs/MICROMIX_ROADMAP.md), not a replacement for them. Check off work only with evidence; implementation alone does not satisfy a manual audio-quality gate.

## Current state, reconciled against the roadmap

- The native app has seven selectable modes plus GUIDE: Generate, Reimagine, Analyze, Transcribe, Vocal Swap, Stem Split, and Library. GUIDE implements cover, remix, transcription, and vocal-swap chains ([DeviceWindow](MacOS/sources/App/DeviceWindow.swift), [Guide](MacOS/sources/Guide/WorkflowGuide.swift)). Chaining, results, playback, library relationships, and export exist, but their complete real-model experience is not yet accepted. Guided Remix prepares and hands off a source to Reimagine rather than automatically completing the remix ([implementation](MacOS/sources/Guide/GuidedRemix.swift)). Overarching source/progress/result standardization across tools is partial.
- Generate and Reimagine already implement seeded alternatives, creative metadata, English/Vietnamese language intent, and reference/remix/repaint flows. Do not reimplement those Phase 1 items; evaluate their consistency and quality. Audio-conditioned Complete and conditional output-format choices remain open ([engine](services/local-inference/local_inference/engines.py)).
- Private voice selection, prepared-vocal conversion, and target/residual stem splitting exist. Guided Vocal Swap can split first, but returns converted vocals, not a balanced accompaniment reference ([guided workflow](MacOS/sources/Guide/GuidedVocalSwap.swift)). Automatic full-song quality and Logic handoff remain unproven.
- Audio-to-MIDI, instrument filtering, tempo options, and basic on-device analysis exist; their real-world advantage and quality remain unverified. Vocal Improve, the two-source Mashup workflow, and Complete remain future work, subject to the roadmap's stop conditions.
- Local durable jobs, recovery, cancellation, and provenance have automated coverage. Export includes immediate Library-resolved relatives and available structured provenance; it reports missing related files and records warnings for unavailable original inputs ([export](MacOS/sources/Core/LocalLibrary.swift)). Complete lineage and reproducibility are not guaranteed. Normal Library-to-Vocal Swap re-uploads data; the split-first guide reuses the remote asset ID.
- Existing [manual acceptance notes](docs/evaluations/local-migration.md) report no model inference, listening, visual review, or Logic import at the time of that record. A private evaluation directory already exists; assess its coverage without exposing or replacing private material. Historical results are not evidence of current installed-model readiness.

## 1. Establish a trustworthy baseline

- [ ] Verify installed dependencies, configured model paths and weights, sidecar health/capabilities, and native/sidecar API compatibility. Record exact app, sidecar, model and environment revisions; do not equate health markers with successful model loading.
- [x] Run the sidecar unit suite and native headless tests and record results and exclusions below. Continue to rerun relevant tests as changes are made; desktop interaction is limited to the explicitly authorized Cua Space.
- [ ] Complete the private evaluation corpus: its manifest records missing English vocals, live/noisy audio and instrumental-only cases; source material must be supplied or approved by the user. A repeatable [scorecard](docs/evaluations/scorecard.md) is ready; verify the real material and record manual results privately.
- [ ] With the user performing heavy/manual acceptance, run Generate, Reference, Remix, Repaint, Transcribe, Vocal Swap and Stem Split; cover GUIDE chaining, cancel/restart, Library, preview, bundle export and Logic import. Record outcomes and limitations without committing private audio. Follow the [acceptance checklist](docs/evaluations/local-migration.md).
- [ ] Triage failures into blockers versus follow-up work. Phase 0 closes only when its roadmap exit gate and manual corpus review pass; scoped implementation may proceed in parallel where appropriate.

## 2. Correct and test specific contract and workflow gaps

- [x] Preserve the transcription API's `best-effort` value through job persistence and into the MuScriptor adapter; cover all modes, persistence and forwarding with automated tests ([route](services/local-inference/local_inference/main.py), [adapter](services/local-inference/local_inference/engines.py)). Real-model behavior remains a manual gate.
- [x] Address and test guided-job cancellation during submission across all four flows, including late acceptance, restart and second-stage IDs. Late cancellation/tracking is best effort; an accepted request whose response is lost remains ambiguous.
- [x] Preserve explicit Reimagine meter/language edits during metadata prefill, with focused regression tests ([prefill](MacOS/sources/Reimagine/ReimagineViewModel.swift)).
- [x] Report the configured MuScriptor checkpoint instead of always checking the medium marker, with readiness contract tests. Readiness remains a filesystem/dependency check, not proof of successful inference.
- [x] Enforce MiniMax's confirmed 360-second duration limit without changing ACE limits; added boundary tests.
- [x] Export immediate Library relatives with structured available provenance; fail visibly for missing related files and record absent original inputs in the manifests. Recursive lineage and complete reproducibility are explicitly not promised.
- [x] Audit and document source handoffs. Guided split-to-swap reuses remote IDs; normal Library handoffs re-upload. Cached IDs expire under sidecar retention, so any future optimization must validate identity and fall back safely on missing assets.

## 3. Choose the next product increment from evidence

After baseline findings, select **one** phase, write its narrow design and acceptance tests, and update the roadmap. Recommended first candidate is completing the existing Vocal Swap journey: evaluate separation and private-voice quality on English and Vietnamese material, then—only if results pass—deliver converted stems and a safe, balanced reference using available accompaniment, with lineage and Logic-ready export. Do not presume an acceptable conversion or build a production enhancement around an unproven model.

Alternative priorities, if the evidence favors them:

- **Creative core:** test whether audio-conditioned Complete produces useful arrangement assets and whether additional export formats materially improve Logic handoff.
- **Reliable transcription:** compare MIDI quality, correction effort and runtime with Logic before expanding output types.
- **Vocal Improve or Mashup:** define real input cases and evaluate candidates before building workflows; keep editing and mixing in Logic.
- **Workflow intelligence:** add analysis only when it demonstrably reduces setup in existing creative workflows while preserving user overrides.

## 4. UI findings from Cua `default` Space

Tested the current native build in a macOS 26.5.2 VM with a generated two-second test tone and no sidecar; no inference was run.

- [x] Fix screen-reader mode counts: all seven modes now announce “of 7” ([PanelButton](MacOS/sources/Theme/PanelButton.swift)).
- [x] Correct Analyze/Transcribe heading numbering to match tabs ([Analyze](MacOS/sources/Analyze/AnalyzeScreen.swift), [Transcribe](MacOS/sources/Transcribe/TranscribeScreen.swift)).
- [x] Explain the macOS 26 duration-only fallback and distinguish it from supported macOS 27 features; do not claim structure analysis.
- [x] Show a completed Analyze status after successful selection.
- [x] Distinguish offline, capability error, loading and verified-empty voice states; expose refresh in Vocal Swap and guided studios.
- [x] Review and reduce header/navigation height at 980×675. More controls are visible, although scrolling is still needed for long forms.

## 5. Keep documentation current

- [x] Reconcile roadmap implementation notes without marking manual quality gates complete; distinguish seven selectable modes from GUIDE.
- [x] Date historical acceptance evidence and reference subsequent checks; retain migration instructions where their relevance is not established.
- [x] Correct [model capability notes](MODEL_CAPABILITY_GAP_ANALYSIS.md), including vocal-language and planner-loading statements.

## Verification for this review

- `git fetch origin` and `git pull --ff-only`: already up to date; the intentionally relocated `skills/SKILL.md` remains untracked and untouched by the audit.
- 2026-11-06 implementation follow-up: from `services/local-inference`, `.venv/bin/python -m unittest discover -s tests -v` — 46 tests passed; Starlette emitted a deprecation warning. From `MacOS`, `xcodebuild test -project Micromix.xcodeproj -scheme Micromix -destination 'platform=macOS' -skip-testing:MicromixTests/DeviceWindowTests -derivedDataPath /tmp/micromix-headless-plan-tests CODE_SIGNING_ALLOWED=NO` — 135 tests passed; visual DeviceWindow tests excluded. These tests do not prove real inference or audio quality.
- 2026-11-06 local preflight: macOS 27.2, Python 3.12.14, HEAD `834b98f` plus uncommitted changes; ACE, MuScriptor and MLX isolated interpreters are present. The already-running local sidecar reported service and model markers ready. Actual native `HealthStatus` and `Capabilities` types decoded its live GET responses (3 presets, 35 instruments, one private voice). The sidecar was not restarted: this does not verify newly edited code, model loading, job submissions or end-to-end compatibility. Pinned engine revisions are in [MODELS.md](services/local-inference/MODELS.md).
- 2026-11-06 focused Cua `default` retest: mode accessibility counts and headings, duration-only messaging and completed status, offline voice guidance/refresh, and 980×675 layout checked. A temporary mock (now stopped) verified empty catalog, capabilities error and refresh recovery; it did not perform inference. Long forms still require scrolling.
- Focused native Analyze tests (3) and API/source-processing suites (23) passed; the requested method-level selector for two other suites selected zero tests, so those individual automated tests were not counted. Bundle export (6) and MiniMax duration boundary tests passed separately. Inference, listening, real-model visual review, and Logic acceptance remain manual and were not run.
