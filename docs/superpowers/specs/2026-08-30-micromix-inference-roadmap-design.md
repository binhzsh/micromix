# Micromix Inference Feature Landscape and Roadmap

**Date:** 2026-08-30
**Status:** historical discovery; superseded by `docs/MICROMIX_ROADMAP.md`
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

The next feature phase should be a **Logic-complementary Reimagine workflow**:

1. Keep the deployed durable input/output asset graph as the foundation.
2. Add ACE-Step reference-audio generation, Remix/Cover, and Repaint.
3. Add restart-safe Mac reattachment, provenance, and only the inference controls
   that materially affect reproducibility or source transformation.
4. Use local Music Understanding only as inference preflight metadata, not as a
   competing tempo, chord, or arrangement environment.
5. Build neural voice identity conversion around vocal stems prepared in Logic;
   keep cleanup or pitch handling internal and optional when conversion quality
   requires it.
6. Retain MuScriptor only for its differentiated polyphonic or multi-instrument
   transcription value, verified against Logic's monophonic audio-to-MIDI path.

This ordering makes Micromix the fast, reproducible AI/ML workspace and keeps
Logic as the project-aware finishing environment. Overlap is permitted when a
Micromix operation is materially simpler, batchable, reproducible, model-specific,
or required by a model pipeline; it must not become a second general editor.

### 2.1 Product boundary after the Logic Pro audit

Logic Pro is the production environment. Micromix should not duplicate work that
is faster, more editable, and better integrated there. Micromix owns heavyweight
or specialized model transformations that Logic does not expose.

| Workflow | Product owner | Micromix decision |
| --- | --- | --- |
| Full-song generation, source-conditioned reimagining, semantic remix, localized generative replacement | Micromix/ACE-Step | Build next |
| Neural singer identity conversion using private voice models | Micromix/RVC or Applio | Build after Reimagine |
| Polyphonic or multi-instrument audio transcription | Micromix/MuScriptor | Maintain and benchmark |
| Stem separation into vocals, drums, bass, guitar, piano, and other | Logic Stem Splitter | Evaluate a one-click prep/export utility only after a quality and speed benchmark |
| Tempo/key/chord analysis | Logic Smart Tempo, Chord ID, and Flex Time | Automatic inference preflight and provenance only; no interactive editor |
| Chord-driven accompaniment | Logic Session Players | Do not build |
| Vocal pitch correction and detailed pitch/timing editing | Logic Pitch Correction and Flex Pitch | Logic-first; allow only hidden conversion-required correction |
| Saturation, mix polish, and final mastering | Logic ChromaGlow and Mastering Assistant | Do not build |
| Lyric rewriting | Logic Notepad Writing Tools | Do not build a generic writing assistant |
| Recording, comping, arrangement, mixing, and delivery | Logic Pro | Explicitly outside Micromix |

The intended round trip is therefore:

1. Import a source, mix, region, or vocal stem into Micromix.
2. Use one-click model transforms, analysis, preflight, and alternates there,
   retaining source and parameter provenance.
3. Import the chosen assets into Logic for comping, cutting, arrangement,
   detailed edits, mixing, and mastering.

### 2.2 Logic Pro 12.3 intelligence audit

Apple's current Logic Pro product page groups Session Players, Stem Splitter,
Mastering Assistant, Chord ID, Pitch Correction, Smart Tempo, and ChromaGlow
under its intelligence features. The current guide and release documentation
add the following practical boundaries:

| Logic capability | Current behavior relevant to Micromix | Roadmap consequence |
| --- | --- | --- |
| Session Players | AI-driven synth, bass, keyboard, and drum performances follow the Chord Track and can be regenerated or converted to MIDI | Reject generic backing-band, accompaniment, and chord-following generation |
| Chord ID | Extracts chords from audio or MIDI directly into the Chord Track | Reject standalone chord detection; retain only hidden key/harmony metadata needed by an inference request |
| Stem Splitter | On Apple silicon, extracts vocals, drums, bass, guitar, piano, and other, with presets and custom submixes | Remove fixed separation from the planned core cover pipeline |
| Pitch Correction | Uses machine-learning pitch detection for real-time scale/chord-aware vocal correction | Reject user-facing autotune duplication |
| Flex Pitch | Analyzes monophonic pitch, edits pitch/timing, quantizes notes, and creates MIDI | Position MuScriptor around polyphonic and multi-instrument transcription, not generic audio-to-MIDI |
| Smart Tempo and Flex Time | Analyze musical tempo, map beats/downbeats, conform recordings or imported audio, and stretch material to project tempo | Reject Micromix tempo-alignment, beat-grid, and time-stretch tooling |
| ChromaGlow | AI-modeled tube, tape, preamp, and compression coloration | Reject generic analog warmth or saturation processing |
| Mastering Assistant | Analyzes a mix and applies adjustable EQ, dynamics, stereo, timbre, and loudness processing | Reject Matchering and automatic final mastering |
| Writing Tools | Apple Intelligence can rewrite text and assist with lyrics in Notepad | Reject a generic lyric rewriting assistant; model-specific prompt formatting may remain internal |
| Flashback Capture | Restores recent audio or MIDI performances even when record was not engaged | No overlap to build; capture belongs to the DAW |
| Logic Pro 12.3 loop/Flex updates | Improve loop/downbeat detection, tempo metadata, and independent tempo/pitch following | Further reason not to reproduce loop conforming or elastic-audio utilities |

This audit should be repeated when Logic adds material intelligence features.
An overlap is not automatically forbidden when Micromix needs an operation
inside a server pipeline, but such an operation must remain an internal stage or
demonstrably outperform Logic on a repeated real-world use case.

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
- Phase 1B gateway operations: reference-audio generation, Remix/Cover,
  Repaint, deterministic one-to-four variations, source/output asset links,
  atomic multiple-output persistence, and bounded ACE recovery.

### 3.2 Important current gaps

- The Mac client does not yet expose Phase 1B reference, Remix/Cover, Repaint,
  seed, variation, BPM, key, or time-signature controls.
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
| Pipeline-only source cleanup | RTX 3090 | Use only when it measurably improves a model transformation |
| Neural voice identity conversion | RTX 3090 | CUDA models and existing Maestro implementations |
| Minimal deterministic render | `lts1` CPU/GPU as required | Assemble model outputs when a workflow requires it |
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

### Phase 1A — Durable asset foundation (deployed)

- Reusable uploaded input assets.
- Multiple typed output assets.
- Normalized asset/job relationships and backward-compatible responses.
- Shared retention behavior for uploaded and generated assets.

### Phase 1B — Reimagine operations (server deployed; native controls next)

#### Functional scope

- The gateway submits and recovers source-audio jobs across restarts; the next
  Mac phase adds client reattachment and provenance controls.
- Add ACE-Step reference-audio conditioning.
- Add Remix/Cover for broad reinterpretation of a source.
- Add Repaint with an explicit time range for localized replacement.
- Support seed, BPM, key, time signature, and two-to-four variations.
- Request and persist only Music Understanding metadata that directly improves
  source selection or an ACE-Step request. Initially this is key, BPM, and
  structure; add other dimensions only when a model contract consumes them.
- Prefill compatible fields from local analysis while retaining user override
  and recording the actual submitted values. Do not turn Analyze into a chord,
  beat-grid, or tempo-editing surface.
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

### Phase 2 — Voice identity conversion

Build one narrow `Convert a Vocal` workflow from selected Maestro components:

1. Accept a vocal stem prepared and, when desired, tuned in Logic Pro.
2. Optionally apply model-specific cleanup only when it improves conversion.
3. Convert vocal identity through an explicitly selected private RVC/Applio
   model without acquiring or sharing third-party voices.
4. Return the dry converted stem and provenance to Logic Pro.

Do not port Maestro's fixed separator, mixer, tuning UI, or Matchering service as
part of this phase. Logic Pro owns separation, pitch correction, recombination,
and mastering. A server-side separator or correction stage can be reconsidered
only for unattended batch chaining or after a focused benchmark demonstrates a
repeatable quality advantage.

Reuse candidates from `~/apps/maestro` on `lts1`:

| Maestro component | Potential Micromix role | Disposition |
| --- | --- | --- |
| `services/separator` | Fixed vocal/instrumental or multistem separation | Do not port by default; Logic owns this workflow |
| `services/applio` | Voice conversion plus F0/autotune controls | Evaluate conversion path; keep tuning internal |
| `services/rvc` | Dedicated RVC training/conversion | Retain as fallback/reference implementation |
| `services/resemble-enhance` | Denoise and vocal enhancement | Evaluate only as conversion preflight |
| `services/mixer` | Trim, combine, pitch, vocal chain, render/bounce | Do not port as a product surface |
| `services/matchering` | Reference-based final mastering | Reject; Logic Mastering Assistant owns finalization |
| Gateway asset chaining | Input/output references and recovery semantics | Reuse concepts/tests, not gateway wholesale |

Voice-model training is not required to prove the cover pipeline. Begin with an
existing user-owned model. Add private training only after conversion quality
and the end-to-end workflow are validated.

### Phase 3 — Differentiated transcription and interchange

Benchmark MuScriptor against Logic's Flex Pitch audio-to-MIDI workflow using the
private evaluation corpus. Continue investment only where MuScriptor provides a
clear advantage: polyphonic material, multi-instrument transcription, useful
instrument filtering, or richer score/event exports. Improve Logic-friendly MIDI
and MusicXML interchange where the benchmark justifies it.

Tempo alignment, time stretching, chord extraction, arrangement primitives,
mixing, and mastering are removed from this phase because Logic already provides
editable, project-aware implementations.

### Phase 4 — Selective advanced capabilities

Only promote items from the catalog below when a repeated workflow justifies
their complexity and Logic does not already own it. Likely candidates are
ACE-Step Complete, semantic or targeted source transformation, improved
MuScriptor export, and private style adaptation.

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
| Reference audio/style conditioning | Gateway deployed | Now | Add native controls; highest-value bridge between an existing song and generation |
| Remix/Cover | Gateway deployed | Now | Add native controls for broad source reinterpretation |
| Repaint | Gateway deployed | Now | Add native controls for localized repair/replacement |
| Seed control | Gateway deployed | Now | Add native control for reproducibility and variation comparison |
| BPM, key, time signature | Gateway deployed | Now | Prefill from local analysis; allow override |
| Multiple variations/batch | Gateway deployed | Now | Add native alternative selection and import every output |
| Output format selection | Missing | Evaluate | WAV/WAV32 for production; compressed formats mainly for previews |
| Vocal language | Missing | Evaluate | Add when multilingual lyrics are actively used |
| Complete/continuation | Missing | Evaluate | Useful for extending sketches once source-asset handling exists |
| Lego/multitrack generation | Missing | Evaluate | Potential stem-aware creation; base/SFT model requirement raises cost |
| Extract/targeted source isolation | Missing | Evaluate | Consider only semantic targets Logic Stem Splitter cannot isolate |
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
| Key detection | Partial | Maintain | Use as inference prefill; Logic owns interactive harmonic editing |
| BPM/rhythm | Partial | Maintain | Use aggregate inference metadata; Logic owns beat maps and conforming |
| Instrument activity | Partial | Evaluate | Expand only when it drives an inference request or source choice |
| Structure | Missing | Next | Add when it drives source selection or Repaint ranges |
| Pace | Missing | Evaluate | Add only when an inference contract consumes it |
| Loudness | Missing | Evaluate | Logic owns production metering; retain only if render safety needs it |
| Incremental/stream analysis | Missing | Evaluate | Useful for long recordings; unnecessary for initial file workflow |
| Server-side ACE audio understanding | Missing | Evaluate | Fallback/cross-check for unsupported Macs or model-specific captioning |
| Custom sound-event classification | Missing | Defer | Sound Analysis is capable, but no core workflow currently needs it |
| Catalog/song recognition | Missing | Defer | ShazamKit identification does not materially advance creation |
| Chord detection | Logic-owned | Reject | Chord ID already analyzes audio/MIDI into the Chord Track |
| Vocal melody/pitch contour | Logic-owned | Reject | Flex Pitch and Pitch Correction own tuning diagnostics and edits |
| Similarity/duplicate detection | Missing | Defer | Could help a large library, but current solo library is small |

### 6.3 Separation, vocals, and source repair

| Capability | Status | Priority | Notes |
| --- | --- | --- | --- |
| Vocal/instrumental separation | Logic-first | Evaluate | Consider a one-click model prep/export utility only if a benchmark is faster or better for Micromix workflows |
| Multistem separation | Logic-first | Evaluate | Same benchmark gate; no stem editor or mixing surface |
| Prompt-based separation | Maestro only | Defer | Powerful but less predictable than fixed stem targets |
| Vocal denoise/enhancement | Maestro only | Evaluate | Internal conversion preflight only; benchmark before use |
| RVC voice conversion | Maestro only | Next | Use private, user-selected voice models |
| F0/autotune correction | Logic-owned | Reject | Tune in Logic; retain only hidden model-required F0 handling |
| Voice-model training | Maestro only | Defer | Not needed for first complete workflow |
| De-essing/breath/noise controls | DSP/model dependent | Evaluate | Add only in response to recurring cleanup failures |
| Source restoration/upscaling | Missing | Evaluate | Useful for archival material, but outside the first cover path |
| Speech/TTS systems | Maestro only | Defer | GPT-SoVITS and Higgs TTS are not core music-cover requirements |

### 6.4 MIDI, score, and transcription

| Capability | Status | Priority | Notes |
| --- | --- | --- | --- |
| Audio-to-MIDI | Implemented | Evaluate | Keep only where polyphonic/multi-instrument results beat Logic's monophonic Flex Pitch path |
| Instrument filtering | Implemented | Maintain | Useful practical constraint |
| Tempo detection toggle | Implemented | Maintain | Preserve source tempo when desired |
| Small/medium/large MuScriptor models | Configurable server env | Evaluate | Benchmark accuracy, VRAM, and latency before exposing profiles |
| Sampling temperature | Missing | Defer | Specialist recovery control, not normal workflow |
| Beam search | Missing | Evaluate | Consider only if measurable transcription accuracy improves |
| Batch/prelude forcing | Missing | Defer | Advanced transcription behavior |
| Event stream output | Missing | Evaluate | Structured note/event editing may eventually benefit |
| JSON/JSONL output | Missing | Evaluate | Useful for analysis pipelines, less useful to Logic directly |
| Auralized check mix | Missing | Evaluate | Helpful for validating transcription without opening Logic |
| Quantized MIDI | Missing | Evaluate | Logic owns quantization; add only if transcription accuracy requires it before export |
| MusicXML | Missing | Evaluate | Useful for notation workflows |
| Full score PDF | Missing | Defer | Requires MuseScore and is not central to Logic workflow |
| Per-instrument PDFs/tabs | Missing | Defer | Retain as a future notation option |
| Lyrics transcription and LRC | Maestro only | Evaluate | Faster-Whisper path is useful for importing existing vocals |
| Basic Pitch | Maestro only | Defer | Redundant unless it outperforms MuScriptor on a targeted case |

### 6.5 Mixing, mastering, and delivery

| Capability | Status | Priority | Notes |
| --- | --- | --- | --- |
| Trim/combine/render | Logic-owned | Reject | Arrangement and bounce belong in Logic |
| Input trim, silence removal, level safety | Missing | Evaluate | Permit a one-click preflight only when it improves a model input or export consistency |
| Gain/pan/fades/crossfades | Logic-owned | Reject | Arrangement and mixing belong in Logic |
| Pitch shift | Logic-owned | Reject | Flex Pitch, Pitch Shifter, and region transpose cover this |
| Time stretch/tempo match | Logic-owned | Reject | Smart Tempo and Flex Time cover this |
| Vocal processing chain | Logic-owned | Reject | Keep only model-required preprocessing internal |
| Loudness normalization | Logic-owned | Reject | Logic owns delivery loudness and final bounce |
| Compression/limiting | Logic-owned | Reject | Mixing and mastering belong in Logic |
| Reference mastering | Logic-owned | Reject | Mastering Assistant replaces the planned Matchering path |
| Stem bundle export | Conditional | Evaluate | Export multiple model outputs when produced; do not create stems merely to duplicate Logic |
| WAV/WAV32/AIFF export | Partial | Next | Production formats first |
| MP3/AAC/Opus export | Upstream ACE only | Evaluate | Convenience preview/share copies |
| Direct Logic project creation | Missing | Defer | High integration cost; stable file export is sufficient initially |

### 6.6 Workflow, reliability, and provenance

| Capability | Status | Priority | Notes |
| --- | --- | --- | --- |
| Durable queued jobs | Implemented | Maintain | Preserve the current coordinator |
| Server restart recovery | Implemented | Maintain | Extend to every new worker/operation |
| Mac job reattachment | Missing | Now | Use existing job listing and recorded local pending jobs |
| Multiple result assets | Implemented | Maintain | Deployed durable asset foundation supports named outputs |
| Input asset upload/reference | Implemented | Maintain | Deployed reusable transient upload contract |
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

### Full cover pipeline first

This would most directly realize vocal swapping, but it introduces separation,
enhancement, conversion, tuning, mixing, multiple assets, and failure recovery
at once. The Logic audit also shows that separation, tuning, mixing, and
mastering already have stronger project-aware homes. The revised voice phase
therefore accepts a prepared stem and returns a converted stem.

### Local utility foundation first

Completing Apple analysis before server inference would be low risk, but it
would delay the differentiated source-audio capabilities already available in
ACE-Step and risk duplicating Logic. Local analysis therefore grows only when a
specific inference contract consumes the result.

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
source preservation, and usefulness after import into Logic. An overlapping
tool must show a repeatable advantage over Logic on this corpus or be required
as an internal unattended-pipeline stage before it can enter the roadmap.

New jobs require contract tests, persistence/recovery tests, adapter tests, and
an `lts1` smoke test. Audio quality acceptance remains a manual listening task;
desktop automation is neither needed nor permitted by repository policy.

## 8.1 Revised overlap rule and candidate shortlist

An overlap may enter Micromix only if it passes at least one of these tests:

- it is a necessary internal stage for a differentiated model workflow;
- it turns a repeated multi-step Logic detour into one intentional action;
- it can run unattended across variants or batches with retained provenance; or
- it measurably improves quality, speed, or reliability on the private corpus.

The next candidates, in order, are: (1) a narrow private vocal-conversion
workflow; (2) an optional benchmarked stem-prep/export utility; (3) compact
model-input preflight for silence trimming, safe level normalization, and
analysis-derived metadata; and (4) enriched polyphonic transcription export.
None implies a general waveform editor, mixer, pitch editor, arranger, or
mastering surface.

## 9. Source inventory

### Repository sources

- `README.md` — current durable MVP architecture and endpoints.
- `services/micromix-api/` — current job, asset, adapter, and recovery model.
- `services/ace-step/` — pinned ACE-Step worker.
- `services/muscriptor-worker/` — current audio-to-MIDI worker.
- `MacOS/sources/Audio/LocalMusicAnalyzer.swift` — current local analysis scope.
- `MacOS/sources/Core/Models.swift` — current durable remote job and provenance
  model.

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
- [Logic Pro User Guide: What’s new](https://support.apple.com/guide/logicpro/whats-new-in-logic-pro-lgcp4a62a494/mac)
- [AVFoundation offline audio processing](https://developer.apple.com/documentation/avfaudio/performing-offline-audio-processing)
- [Apple Foundation Models](https://developer.apple.com/documentation/foundationmodels)
- [ShazamKit](https://developer.apple.com/shazamkit/)
- [Logic Pro for Mac 12.3: What's new](https://support.apple.com/guide/logicpro/whats-new-in-logic-pro-lgcp4a62a494/mac)
- [Logic Pro intelligence features](https://www.apple.com/logic-pro/)
- [Apple's 2026 Logic Pro intelligence announcement](https://www.apple.com/newsroom/2026/01/introducing-apple-creator-studio-an-inspiring-collection-of-creative-apps/)
- [Session Players overview](https://support.apple.com/guide/logicpro/session-players-overview-lgcpbf624405/mac)
- [Chord ID](https://support.apple.com/guide/logicpro/analyze-chords-audio-midi-regions-logic-pro-lgcp4993e80c/mac)
- [Stem Splitter](https://support.apple.com/guide/logicpro/extract-vocal-instrumental-stems-stem-lgcp61bae908/mac)
- [Pitch Correction](https://support.apple.com/guide/logicpro/pitch-correction-effect-lgcef2835dcc/mac)
- [Flex Time and Pitch](https://support.apple.com/guide/logicpro/flex-time-and-pitch-overview-lgcp15968647/mac)
- [Flex Pitch audio-to-MIDI](https://support.apple.com/guide/logicpro/create-midi-from-audio-recordings-lgcpe2fd1b83/mac)
- [Smart Tempo](https://support.apple.com/guide/logicpro/smart-tempo-overview-lgcp9281e70c/mac)
- [ChromaGlow](https://support.apple.com/guide/logicpro/chromaglow-lgcp0a30400b/mac)
- [Mastering Assistant](https://support.apple.com/guide/logicpro/mastering-assistant-overview-lgcp7f94da0b/mac)
- [Logic Pro 11.2 features and Writing Tools](https://www.apple.com/newsroom/2025/05/logic-pro-amplifies-beat-making-on-mac-and-ipad-with-advanced-new-capabilities/)

## 10. Immediate follow-up

Phase 1 is complete: durable assets, ACE-Step reference generation, Remix/Cover,
Repaint, native job reattachment, provenance, and concise controls are deployed.
Use `docs/MICROMIX_ROADMAP.md` for all current product direction, phase ordering,
task status, and acceptance gates. This document remains historical capability
discovery only.
