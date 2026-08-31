# Micromix Inference Feature Landscape and Roadmap

**Date:** 2026-08-30
**Status:** approved product direction; implementation not started
**Scope:** inference, audio processing, model capabilities, and supporting data
contracts. Visual and UI work is intentionally excluded.

## 1. Purpose

This document records the complete inference-feature discovery for Micromix so
that potentially useful capabilities are not lost, while identifying the small
set worth building next.

Micromix is a private, solo-user macOS companion to Logic Pro. It should make
reimagining songs faster: generate material, understand recordings, remix or
repair sections, create covers, swap or tune vocals, prepare stems, and return
useful audio or MIDI to the DAW. It is not intended to become a DAW, public
service, collaboration platform, or general model playground.

The architectural split remains:

- The MacBook Pro owns the native experience, authoritative library, playback,
  fast local analysis, and low-latency previews.
- `lts1` owns heavyweight inference and reproducible server renders using its
  RTX 3090.
- The durable Micromix API remains the only backend contract exposed to the Mac.

## 2. Decision summary

The next feature phase should be an **asset-aware Reimagine workflow**:

1. Extend durable jobs from output-only files to explicit input assets, output
   assets, provenance, and restart-safe client reattachment.
2. Add ACE-Step reference-audio generation, Remix/Cover, and Repaint.
3. Expose only high-value controls: seed, BPM, key, time signature, and a small
   variation count.
4. Expand local Apple Music Understanding analysis to all six available
   dimensions and use it to prefill inference metadata.
5. After that foundation is stable, build a selective Maestro-derived cover
   pipeline: separate, clean/tune, convert the voice, recombine, and master.
6. Add deterministic mashup and arrangement utilities after the cover pipeline.

This ordering produces a useful new creative result with the already deployed
ACE-Step stack, while building the asset graph needed by covers, stems,
transcription, and later multitrack operations.

## 3. Current baseline

### 3.1 Implemented

- ACE-Step 1.5 XL Turbo and XL SFT/Quality text-or-lyrics-to-music generation.
- Durable SQLite-backed jobs with queueing, polling, cancellation, restart
  recovery, SHA-256 result metadata, downloads, and seven-day server retention.
- GPU-router acquisition/release for ACE-Step and MuScriptor.
- MuScriptor audio-to-MIDI with instrument selection and optional tempo
  detection.
- Local SwiftData library containing downloaded generated audio and MIDI.
- Local file inspection through AVFoundation and, on supported systems, Apple
  Music Understanding for rhythm, key, and instrument activity.
- Generate, Analyze, Transcribe, and Library app workflows.

### 3.2 Important current gaps

- The API has only `generation` and `transcription` job kinds.
- A job has one optional output asset and no modeled input-asset relationship.
- ACE-Step accepts no source or reference audio through the Micromix gateway.
- Remix/Cover, Repaint, Lego, Extract, and Complete are not exposed.
- The gateway accepts seed, BPM, key, and time signature, but the Mac generation
  client does not send them.
- Jobs can be listed, but the Mac does not restore or reattach to unfinished jobs
  after app restart.
- The library records a result file, not its source assets, transformations,
  parameter history, parent result, or alternate versions.
- Local analysis stores only duration, BPM, key, and instruments. Structure,
  pace, loudness, beat/bar timestamps, and analysis confidence are not retained.
- MuScriptor returns one MIDI asset. Its richer upstream event, score, and
  auralization outputs are not exposed.
- There is no stem separation, vocal conversion/tuning, enhancement, mixing,
  mastering, or deterministic mashup pipeline in Micromix.

## 4. Recommended architecture

### 4.1 Asset-aware durable jobs

Avoid adding a separate endpoint and storage convention for every model. First
make the durable job layer capable of representing creative transformations.

Each job should eventually support:

- zero or more immutable input asset references;
- one or more typed output assets;
- a job operation and versioned parameter payload;
- parent/derived relationships between assets;
- hashes, media type, duration, sample rate, channels, and optional music
  metadata;
- enough upstream identity to recover or reconcile work after a restart; and
- local import of the completed outputs before server retention expires.

The Mac library remains authoritative. Server assets are transient working
files, not a second user library. A lightweight local provenance record should
be sufficient; a full collaborative project database is unnecessary.

This foundation is required before variations, stems, or score bundles because
all three naturally return multiple outputs.

### 4.2 Compute placement

| Work | Preferred location | Reason |
| --- | --- | --- |
| Playback, waveform extraction, file metadata | M2 Max | Immediate, private, no transfer |
| Music Understanding analysis | M2 Max | Apple-optimized and offline |
| Preview trim, gain, fades, simple effects | M2 Max/AVFoundation | Low-latency auditioning |
| ACE-Step generation and audio editing | RTX 3090 | Existing CUDA deployment and model cache |
| Stem separation | RTX 3090 | Large separation models; proven Maestro service |
| Vocal conversion, tuning, enhancement | RTX 3090 | CUDA models and existing Maestro implementations |
| Final deterministic render | `lts1` CPU/GPU as required | Reproducible pipeline and fewer large transfers |
| Logic Pro arrangement and final production | Mac | The DAW remains the production destination |

Apple Foundation Models may later help rewrite prompts, structure lyrics, or
produce metadata, but it should not become a second audio planner. ACE-Step's
own language model already performs generation-specific planning.

### 4.3 Model-service policy

- Keep one stable Micromix API; workers remain private implementation details.
- Add workers only for a concrete workflow, not merely because a model exists.
- Prefer deterministic DSP for trim, alignment, gain, fades, and final assembly.
- Prefer a specialized model where its output quality materially exceeds DSP.
- Pin code and model revisions and record the effective model/profile on jobs.
- Treat user-selected source audio and private voice models as local/private
  assets. Do not add sharing, catalogs, or third-party voice acquisition.
- Port selected Maestro implementations and tests; do not transplant Maestro's
  web app or entire gateway.

## 5. Delivery phases

### Phase 1 — Reimagine foundation (next)

#### Functional scope

- Upload/import an audio source as a durable job input.
- Model input/output asset relationships and multiple outputs.
- Submit and recover source-audio jobs across gateway and app restarts.
- Add ACE-Step reference-audio conditioning.
- Add Remix/Cover for broad reinterpretation of a source.
- Add Repaint with an explicit time range for localized replacement.
- Support seed, BPM, key, time signature, and two-to-four variations.
- Request and persist all Apple Music Understanding dimensions:
  - key;
  - rhythm, including BPM and beat/bar positions;
  - structure;
  - pace;
  - instrument activity; and
  - loudness.
- Prefill compatible ACE-Step fields from local analysis while retaining user
  override and recording the actual submitted values.
- Import every successful output into the local library before expiry.

#### Explicit non-goals

- No new visual redesign.
- No LoRA training.
- No arbitrary low-level diffusion or language-model tuning controls.
- No voice conversion or stem editor yet.
- No general workflow-builder abstraction.

#### Acceptance outcomes

- A local song can produce a reference-guided variation.
- A source can be remixed without losing the original.
- A selected passage can be repainted while preserving the rest of the source.
- Repeated seeds and recorded parameters make a result reproducible within the
  limits of the pinned model stack.
- Closing and reopening the app does not orphan a submitted job.
- Each local result shows which source and transformation produced it.

### Phase 2 — Cover and vocal pipeline

Build one coherent `Cover a Song` pipeline from selected Maestro components:

1. Separate the source into at least vocal and instrumental stems.
2. Optionally clean the vocal with Resemble Enhance.
3. Tune/correct pitch using Applio's F0/autotune controls when requested.
4. Convert the vocal through an explicitly selected private RVC/Applio model.
5. Recombine converted vocal and instrumental with deterministic level controls.
6. Produce an unmastered mix and an optional mastered result.

Start with the proven fixed stem separator rather than prompt-based separation.
Fixed vocal/instrumental separation is predictable and directly supports the
workflow. Evaluate ACE-Step Extract against it using real material before
choosing ACE-Step as a replacement.

Reuse candidates from `~/apps/maestro` on `lts1`:

| Maestro component | Potential Micromix role | Disposition |
| --- | --- | --- |
| `services/separator` | Fixed vocal/instrumental or multistem separation | Port first, with current tests |
| `services/applio` | Voice conversion plus F0/autotune controls | Preferred combined vocal path to evaluate |
| `services/rvc` | Dedicated RVC training/conversion | Retain as fallback/reference implementation |
| `services/resemble-enhance` | Denoise and vocal enhancement | Optional stage |
| `services/mixer` | Trim, combine, pitch, vocal chain, render/bounce | Reuse deterministic operations selectively |
| `services/matchering` | Reference-based final mastering | Optional final stage |
| Gateway asset chaining | Input/output references and recovery semantics | Reuse concepts/tests, not gateway wholesale |

Voice-model training is not required to prove the cover pipeline. Begin with an
existing user-owned model. Add private training only after conversion quality
and the end-to-end workflow are validated.

### Phase 3 — Mashup and arrangement utilities

Prioritize predictable DAW-adjacent operations:

- beat-grid and downbeat-aware region selection;
- automatic tempo estimation and alignment;
- high-quality time stretching;
- key estimation and semitone pitch matching;
- trim, crop, loop, fades, crossfades, gain, and pan;
- vocal/instrumental replacement;
- ordered timeline assembly and bounce;
- loudness measurement, normalization, limiting, and optional reference
  mastering; and
- export of stems and final renders in Logic-friendly formats.

These utilities are more useful for real mashups than adding another generative
model. They should remain explicit operations rather than an opaque autonomous
arranger.

### Phase 4 — Selective advanced capabilities

Only promote items from the catalog below when a repeated workflow justifies
their complexity. Likely candidates are ACE-Step Complete, targeted instrument
extraction, improved MuScriptor export, and private style adaptation.

## 6. Full potential feature catalog

Priority meanings:

- **Now:** belongs in Phase 1.
- **Next:** coherent Phase 2 or 3 capability.
- **Evaluate:** promising, but requires quality tests or demonstrated need.
- **Defer:** retain for reference; not presently worth the complexity.
- **Reject:** conflicts with the private solo-user product scope.

### 6.1 ACE-Step generation and editing

| Capability | Status | Priority | Notes |
| --- | --- | --- | --- |
| Text-to-music | Implemented | Maintain | Turbo and Quality presets already cover fast exploration and better renders |
| Lyrics-to-song | Implemented | Maintain | Keep structured lyrics and instrumental generation |
| Reference audio/style conditioning | Missing | Now | Highest-value bridge between an existing song and generation |
| Remix/Cover | Missing | Now | Broad reinterpretation while preserving useful source identity |
| Repaint | Missing | Now | High-value localized repair/replacement with an explicit time range |
| Seed control | Gateway only | Now | Reproducibility and variation comparison |
| BPM, key, time signature | Gateway only | Now | Prefill from local analysis; allow override |
| Multiple variations/batch | Missing | Now | Cap at a small practical count; requires multiple output assets |
| Output format selection | Missing | Evaluate | WAV/WAV32 for production; compressed formats mainly for previews |
| Vocal language | Missing | Evaluate | Add when multilingual lyrics are actively used |
| Complete/continuation | Missing | Evaluate | Useful for extending sketches once source-asset handling exists |
| Lego/multitrack generation | Missing | Evaluate | Potential stem-aware creation; base/SFT model requirement raises cost |
| Extract/track separation | Missing | Evaluate | Benchmark against the dedicated separator before adoption |
| Audio understanding/captioning | Missing | Evaluate | May complement Apple analysis, particularly on older macOS |
| Cover strength and edit-specific controls | Missing | Now | Expose concise operation-level controls, not raw model internals |
| Prompt formatting helper | Missing | Evaluate | Could use ACE planner or local Foundation Models |
| Thinking-language-model toggle | Missing | Defer | Default behavior should usually be sufficient |
| Dynamic model loading/switching | Internal only | Defer | Operational concern, not a creative feature |
| Low-level DiT/LM guidance and sampling | Missing | Defer | Keep tested presets unless troubleshooting or expert need emerges |
| LoRA/LoKr inference | Missing | Evaluate | Useful only after a private style model exists |
| LoRA/LoKr training | Missing | Defer | Storage, datasets, training UX, validation, and overfitting risk |
| Very long generation up to model limit | Partially exposed | Evaluate | Validate VRAM, latency, coherence, and failure recovery first |
| 50+ language coverage | Upstream capability | Evaluate | Enable based on actual lyric-writing needs, not completeness |

ACE-Step's upstream modes are not interchangeable: Text-to-Music, Remix,
Repaint, Lego, Extract, and Complete have different source requirements, and
some require the base/SFT model rather than Turbo. The gateway should express
them as typed operations instead of one bag of optional parameters.

### 6.2 Analysis and music intelligence

| Capability | Status | Priority | Notes |
| --- | --- | --- | --- |
| Duration/file metadata | Implemented | Maintain | AVFoundation fallback works on all supported targets |
| Key detection | Partial | Now | Persist timestamped ranges/confidence where available |
| BPM/rhythm | Partial | Now | Retain beat and bar locations, not only aggregate BPM |
| Instrument activity | Partial | Now | Persist time ranges and normalize labels carefully |
| Structure | Missing | Now | Sections, segments, and phrases enable editing and arrangement |
| Pace | Missing | Now | Useful descriptive/selection input for generation |
| Loudness | Missing | Now | Integrated, short-term, momentary, and peak values aid rendering |
| Incremental/stream analysis | Missing | Evaluate | Useful for long recordings; unnecessary for initial file workflow |
| Server-side ACE audio understanding | Missing | Evaluate | Fallback/cross-check for unsupported Macs or model-specific captioning |
| Custom sound-event classification | Missing | Defer | Sound Analysis is capable, but no core workflow currently needs it |
| Catalog/song recognition | Missing | Defer | ShazamKit identification does not materially advance creation |
| Chord detection | Missing | Evaluate | Valuable for mashups if accuracy is adequate; not supplied by current local record |
| Vocal melody/pitch contour | Missing | Next | Needed for tuning diagnostics and musical alignment |
| Similarity/duplicate detection | Missing | Defer | Could help a large library, but current solo library is small |

### 6.3 Separation, vocals, and source repair

| Capability | Status | Priority | Notes |
| --- | --- | --- | --- |
| Vocal/instrumental separation | Maestro only | Next | Core prerequisite for covers and vocal swaps |
| Multistem separation | Maestro only | Evaluate | Drums, bass, guitar, piano, and other stems when quality warrants |
| Prompt-based separation | Maestro only | Defer | Powerful but less predictable than fixed stem targets |
| Vocal denoise/enhancement | Maestro only | Next | Resemble Enhance candidate; make bypass/comparison easy |
| RVC voice conversion | Maestro only | Next | Use private, user-selected voice models |
| F0/autotune correction | Maestro only | Next | Applio candidate; retain musical control and dry output |
| Voice-model training | Maestro only | Defer | Not needed for first complete workflow |
| De-essing/breath/noise controls | DSP/model dependent | Evaluate | Add only in response to recurring cleanup failures |
| Source restoration/upscaling | Missing | Evaluate | Useful for archival material, but outside the first cover path |
| Speech/TTS systems | Maestro only | Defer | GPT-SoVITS and Higgs TTS are not core music-cover requirements |

### 6.4 MIDI, score, and transcription

| Capability | Status | Priority | Notes |
| --- | --- | --- | --- |
| Audio-to-MIDI | Implemented | Maintain | Current MuScriptor path supersedes Maestro Basic Pitch |
| Instrument filtering | Implemented | Maintain | Useful practical constraint |
| Tempo detection toggle | Implemented | Maintain | Preserve source tempo when desired |
| Small/medium/large MuScriptor models | Configurable server env | Evaluate | Benchmark accuracy, VRAM, and latency before exposing profiles |
| Sampling temperature | Missing | Defer | Specialist recovery control, not normal workflow |
| Beam search | Missing | Evaluate | Consider only if measurable transcription accuracy improves |
| Batch/prelude forcing | Missing | Defer | Advanced transcription behavior |
| Event stream output | Missing | Evaluate | Structured note/event editing may eventually benefit |
| JSON/JSONL output | Missing | Evaluate | Useful for analysis pipelines, less useful to Logic directly |
| Auralized check mix | Missing | Evaluate | Helpful for validating transcription without opening Logic |
| Quantized MIDI | Missing | Next/Evaluate | High DAW value if timing remains musical |
| MusicXML | Missing | Evaluate | Useful for notation workflows |
| Full score PDF | Missing | Defer | Requires MuseScore and is not central to Logic workflow |
| Per-instrument PDFs/tabs | Missing | Defer | Retain as a future notation option |
| Lyrics transcription and LRC | Maestro only | Evaluate | Faster-Whisper path is useful for importing existing vocals |
| Basic Pitch | Maestro only | Defer | Redundant unless it outperforms MuScriptor on a targeted case |

### 6.5 Mixing, mastering, and delivery

| Capability | Status | Priority | Notes |
| --- | --- | --- | --- |
| Trim/combine/render | Maestro only | Next | Deterministic foundation for covers and mashups |
| Gain/pan/fades/crossfades | Partial Maestro concepts | Next | Necessary arrangement primitives |
| Pitch shift | Maestro only | Next | Improve quality and add key-aware control |
| Time stretch/tempo match | Missing | Next | Essential for mashups; preserve pitch by default |
| Vocal processing chain | Maestro only | Next | Keep stages inspectable and bypassable |
| Loudness normalization | Maestro only | Next | Deterministic delivery baseline |
| Compression/limiting | Maestro only | Next | Conservative defaults; leave creative mix decisions to Logic |
| Reference mastering | Maestro Matchering | Evaluate | Optional alternate output, never overwrite the mix |
| Stem bundle export | Missing | Next | Multiple typed assets, Logic-friendly names and formats |
| WAV/WAV32/AIFF export | Partial | Next | Production formats first |
| MP3/AAC/Opus export | Upstream ACE only | Evaluate | Convenience preview/share copies |
| Direct Logic project creation | Missing | Defer | High integration cost; stable file export is sufficient initially |

### 6.6 Workflow, reliability, and provenance

| Capability | Status | Priority | Notes |
| --- | --- | --- | --- |
| Durable queued jobs | Implemented | Maintain | Preserve the current coordinator |
| Server restart recovery | Implemented | Maintain | Extend to every new worker/operation |
| Mac job reattachment | Missing | Now | Use existing job listing and recorded local pending jobs |
| Multiple result assets | Missing | Now | Required by variations and stems |
| Input asset upload/reference | Missing | Now | Required by every source-audio operation |
| Transformation provenance | Missing | Now | Source, operation, parameters, model revision, result |
| Project/song grouping | Missing | Evaluate | Lightweight grouping may help once results branch |
| Version/branch relationships | Missing | Evaluate | Add when Repaint and cover outputs become numerous |
| Automatic stage chaining | Missing | Next | Cover flow should pass outputs without manual re-upload |
| Retry/resume semantics | Partial | Now | Define idempotency and interrupted upload behavior |
| Progress events/streaming | Polling only | Evaluate | Useful if upstream offers reliable granular progress |
| Cache by content hash | SHA-256 output only | Evaluate | Avoid repeated uploads/analysis where safe |
| Retention-aware local import | Partial | Now | Surface/download outputs before seven-day pruning |
| Per-stage diagnostics | Partial logs | Next | Essential for multi-stage pipeline failures |
| Quality comparison/evaluation harness | Missing | Now/Next | Use a small private reference set before choosing model paths |

### 6.7 Explicitly rejected product expansion

- Web application or browser-first workflow.
- Public API or hosted inference service.
- Accounts, teams, roles, permissions, or collaboration.
- Community voice/style marketplace.
- Publishing, distribution, social sharing, or rights-management platform.
- Autonomous replacement for Logic Pro.
- Multi-user queue fairness, billing, or quota systems.
- Infrastructure for models with no approved Micromix workflow.

## 7. Alternatives considered

### Cover pipeline first

This would most directly realize vocal swapping, but it introduces separation,
enhancement, conversion, tuning, mixing, multiple assets, and failure recovery
at once. Building asset-aware jobs first reduces integration risk and avoids a
one-off pipeline contract.

### Local utility foundation first

Completing Apple analysis and DSP before server inference would be low risk and
useful, but it would delay the differentiated source-audio capabilities already
available in ACE-Step. Local analysis is therefore included in Phase 1 without
making it the entire phase.

### Expose the full ACE-Step API

This is fast at the endpoint level but creates an unstable model-control panel,
leaks worker details into the client, and does not solve asset lineage. Typed,
workflow-oriented operations are preferred.

## 8. Evaluation strategy

Before promoting any `Evaluate` item, test it against a small private corpus
representing actual use:

- a clean studio song;
- a dense mastered mix;
- a live or noisy recording;
- singing with expressive pitch movement;
- instrumental material; and
- at least one long source.

Record runtime, peak VRAM, failure behavior, output format, perceived artifacts,
source preservation, and usefulness after import into Logic. For overlapping
tools—dedicated separator versus ACE Extract, for example—choose based on these
results, not advertised feature breadth.

New jobs require contract tests, persistence/recovery tests, adapter tests, and
an `lts1` smoke test. Audio quality acceptance remains a manual listening task;
desktop automation is neither needed nor permitted by repository policy.

## 9. Source inventory

### Repository sources

- `README.md` — current durable MVP architecture and endpoints.
- `services/micromix-api/` — current job, asset, adapter, and recovery model.
- `services/ace-step/` — pinned ACE-Step worker.
- `services/muscriptor-worker/` — current audio-to-MIDI worker.
- `MacOS/sources/Audio/LocalMusicAnalyzer.swift` — current local analysis scope.
- `MacOS/sources/Core/Models.swift` — current single-asset remote job model.
- `MacOS/docs/superpowers/specs/2026-08-19-micromix-macos-app-design.md` —
  historical MVP scope; backend and persistence contracts are superseded.
- `MacOS/docs/superpowers/plans/2026-10-19-micromix-macos-app.md` — completed
  native application plan.

### Maestro sources inspected on `lts1`

- `~/apps/maestro/services/separator`
- `~/apps/maestro/services/audiosep`
- `~/apps/maestro/services/rvc`
- `~/apps/maestro/services/applio`
- `~/apps/maestro/services/resemble-enhance`
- `~/apps/maestro/services/matchering`
- `~/apps/maestro/services/mixer`
- `~/apps/maestro/services/musicgen`
- `~/apps/maestro/services/basic-pitch`
- `~/apps/maestro/services/stt`
- `~/apps/maestro/services/gpt-sovits`
- `~/apps/maestro/services/higgs-tts`
- Maestro's gateway, `PLAN.md`, OpenSpec material, release evidence, and model
  research notes.

The Maestro checkout was inspected read-only. No service has been copied into
Micromix by this design decision.

### Official upstream references

- [ACE-Step 1.5 musician guide](https://github.com/ace-step/ACE-Step-1.5/blob/main/docs/en/ace_step_musicians_guide.md)
- [ACE-Step 1.5 capabilities](https://ace-step.github.io/ACE-Step-1.5/en/)
- [ACE-Step 1.5 API](https://ace-step.github.io/ACE-Step-1.5/en/API)
- [MuScriptor repository](https://github.com/muscriptor/muscriptor)
- [Apple Music Understanding](https://developer.apple.com/documentation/musicunderstanding)
- [WWDC26: Explore Music Understanding](https://developer.apple.com/videos/play/wwdc2026/253/)
- [Apple Sound Analysis](https://developer.apple.com/documentation/SoundAnalysis)
- [Apple Core ML](https://developer.apple.com/documentation/CoreML)
- [AVFoundation offline audio processing](https://developer.apple.com/documentation/avfaudio/performing-offline-audio-processing)
- [Apple Foundation Models](https://developer.apple.com/documentation/foundationmodels)
- [ShazamKit](https://developer.apple.com/shazamkit/)

## 10. Immediate follow-up

The next implementation design should cover Phase 1 only. It should define the
asset/provenance schema, typed ACE-Step operation contracts, upload lifecycle,
multi-output behavior, restart reconciliation, local analysis record, and a
focused evaluation fixture set before any backend code is changed on `lts1`.
