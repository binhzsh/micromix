# Micromix Product Roadmap

**Status:** canonical source of truth

**Approved:** 2026-08-31

**Product:** private, solo-user native macOS music tooling companion

**Finishing environment:** Logic Pro

## Purpose

Micromix is a small collection of high-leverage creative audio tools and the
preferred starting environment for experimentation. It accepts songs, stems,
vocals, or musical ideas, performs difficult AI transformations, and aims to
produce a coherent result that is roughly 70–80% finished. Logic Pro owns the
last 20–30%: detailed arrangement, comping, editing, mix decisions, and final
mastering.

Micromix is not a DAW, model laboratory, public service, or automated music
publishing system. Its value is making operations such as reimagining a song,
creating a cover, swapping or improving a vocal, preparing mashup assets, and
transcribing complex audio substantially simpler than a manual multi-tool
workflow. When a transformation has multiple useful parts, Micromix should
return both editable component assets and a convincing assembled reference mix.

## Product rules

A feature belongs in Micromix only when it meets all applicable rules:

1. It eliminates an annoying or complicated creative workflow.
2. It produces a useful asset or assembled creative result rather than another
   editing environment.
3. Its normal workflow needs only a few creative controls.
4. It is meaningfully model-driven or better automated outside Logic.
5. Its underlying model has passed a private quality evaluation.
6. It preserves source, model, settings, and output provenance.
7. It gets the result as close to the finish line as safe automation allows,
   while leaving detailed, project-aware decisions to Logic.

Do not expose inference steps, sampling internals, arbitrary model selection,
LoRA controls, prompt-engineering machinery, waveform editing, mixer channels,
plugin racks, automation lanes, or detailed pitch correction. Automatic
alignment, cleanup, balance, transitions, level safety, and reference finishing
belong when they measurably improve the result and do not require a DAW-like
editing surface.

## Product tools

Micromix converges on five excellent tools:

1. **Reimagine** — generate, reference, remix/cover, replace a section, and
   eventually complete a vocal or partial arrangement.
2. **Vocal Swap** — start from a song or vocal stem, prepare and convert the
   vocal to a selected private voice, improve it as needed, and return both
   Logic-ready alternatives and an in-context preview.
3. **Vocal Improve** — reduce noise, reverberation, intelligibility problems,
   and model artifacts while preserving identity and expression.
4. **Mashup** — turn two songs or selected stems into an automatically prepared
   70–80% arrangement plus the isolated and transformed components needed for
   final work in Logic, without adding a timeline or mixer.
5. **Reliable Transcription** — generate validated polyphonic or
   multi-instrument MIDI, and MusicXML only if evaluation demonstrates value.

## Tracking model

This document is the product-level task tracker. Phase checkboxes record
approved outcomes, not individual code changes.

- `[ ]` — not started
- `[~]` — active; a phase design and implementation plan have been approved
- `[x]` — complete; acceptance criteria and manual quality gate have passed
- `[!]` — stopped; evaluation failed or the capability no longer fits the
  product

Only one implementation phase should normally be active. Each phase receives a
narrow design specification and executable implementation plan before code is
changed. A later phase may be reordered when evidence changes, but this file
must be updated in the same commit that approves the change.

## Current baseline

The following foundation is complete:

- [x] Native Generate, Reimagine, Analyze, Transcribe, and Library modes
- [x] ACE-Step Turbo and Quality text/lyrics generation
- [x] Reference generation, Remix/Cover, and time-range Repaint
- [x] Seeds, alternatives, musical metadata, and transformation strength
- [x] Durable jobs, cancellation, restart recovery, assets, and checksums
- [x] Native job reattachment and local authoritative asset import
- [x] Source, parameter, and output provenance
- [x] Apple Music Understanding aggregate BPM, key, and instrument prefill
- [x] MuScriptor polyphonic and multi-instrument audio-to-MIDI

## Phase 0 — Product-quality baseline

**Goal:** establish a trustworthy operational and evaluation baseline before
adding another model workflow.

- [ ] Fast-forward the clean `lts1` checkout to the approved repository commit
      and verify Compose remains healthy.
- [ ] Create a small private evaluation corpus containing clean studio audio, a
      dense mastered mix, live/noisy audio, expressive vocals, instrumental
      material, polyphonic material, and a long source.
- [ ] Define a repeatable scorecard for usefulness, source preservation,
      artifacts, runtime, VRAM, failure recovery, and Logic import.
- [ ] Manually verify Generate, Reference, Remix, Repaint, and Transcribe using
      the corpus.
- [ ] Record current model and service revisions with the evaluation results.
- [ ] Fix release-blocking workflow or reliability defects found by the
      baseline; defer cosmetic improvements that do not affect creative use.

**Exit gate:** the repository checkouts agree, automated tests pass, the live
gateway is healthy, and every existing creative operation has a recorded manual
quality result.

## Phase 1 — Finish the creative core

**Goal:** make Generate and Reimagine feel like one coherent, fast
asset-creation system.

- [ ] Standardize source selection, creative direction, alternatives, progress,
      cancellation, and result presentation across Generate and Reimagine.
- [ ] Add missing high-value Generate controls only where they improve
      reproducibility or creative direction.
- [ ] Evaluate ACE-Step Complete using vocals and partial arrangements.
- [ ] Add Complete only if it consistently returns arrangement assets worth
      continuing in Logic.
- [ ] Make sending an existing library asset into another Micromix tool a
      deliberate one-action handoff.
- [ ] Improve alternative comparison and source/result relationships without
      adding a multitrack editor.
- [ ] Add production audio output choices only when the chosen format materially
      improves the Logic handoff.

**Exit gate:** a user can start from text, a song, a vocal, or a partial idea;
create useful alternatives; understand their lineage; and move chosen assets to
Logic without manual file hunting or parameter re-entry.

**Stop condition:** omit Complete if its evaluated output is not reliably useful.

## Phase 2 — Vocal Swap

**Goal:** produce convincing vocal alternatives in a selected private voice and
place them into enough musical context to judge and use immediately.

- [ ] Accept either a complete song or an already prepared vocal stem.
- [ ] For complete songs, evaluate and select an automatic vocal/accompaniment
      preparation stage before exposing the workflow.
- [ ] Evaluate the existing RVC and Applio capabilities on the private vocal
      corpus.
- [ ] Compare identity transfer, lyric intelligibility, pitch/expression
      preservation, artifacts, runtime, VRAM, and operational reliability.
- [ ] Select one production backend; do not expose backend selection in the app.
- [ ] Define a durable vocal-conversion job with source, target voice, model
      revision, parameters, alternatives, and output provenance.
- [ ] Add a small local private voice library and a simple target-voice picker.
- [ ] Build automatic source preparation to converted vocal alternatives.
- [ ] Add automatic internal preprocessing only when evaluation proves it
      improves conversion without changing the performance.
- [ ] Return the converted vocal stems plus an automatically balanced in-context
      reference mix when accompaniment is available.
- [ ] Verify every stem and reference mix can be imported and polished directly
      in Logic.

**Exit gate:** starting from either a song or vocal stem, at least one private
target voice produces consistently usable conversions across the agreed corpus,
with understandable failures and no manual server/model operation.

**Stop condition:** do not build a production UI if neither backend clears the
quality bar.

## Phase 3 — Vocal Improve

**Goal:** repair common vocal problems with one intentional operation while
preserving the original performance and returning a result ready for creative
use.

- [ ] Evaluate candidate enhancement models on clean, noisy, reverberant, and
      expressive vocals.
- [ ] Measure denoise, dereverberation, intelligibility, identity retention,
      transient damage, and musical artifacts.
- [ ] Select only improvements that are reliably better than the input.
- [ ] Build a minimal Improve Vocal operation returning an improved stem and an
      in-context reference when accompaniment is available.
- [ ] Allow Vocal Swap to use proven improvement stages internally when useful.
- [ ] Preserve both the original and improved/converted lineage.

**Exit gate:** the operation improves recurring real inputs without flattening
expression or requiring a rack of technical controls.

**Stop condition:** reject any enhancement stage that trades obvious musical
damage for cleaner metrics.

## Phase 4 — Mashup and cover assets

**Goal:** turn two songs or selected stems into a coherent 70–80% mashup or
cover result plus editable building blocks for final work in Logic.

- [ ] Define the smallest valuable two-source workflow using real desired
      mashups before choosing models or contracts.
- [ ] Benchmark vocal/instrument extraction against Logic Stem Splitter.
- [ ] Add internal or one-click separation only if it is required for the
      workflow or has a repeatable quality/speed advantage.
- [ ] Evaluate automatic musical compatibility and alignment suggestions using
      Apple analysis without creating an interactive tempo editor.
- [ ] Generate named isolated, transformed, and candidate combination assets.
- [ ] Automatically handle proven alignment, transitions, balance, and level
      safety needed for a convincing assembled reference mix.
- [ ] Preserve both source lineages and every transformation stage.
- [ ] Export the assembled reference mix and separate components for final
      timing, arrangement, mixing, and mastering in Logic.

**Exit gate:** starting from the agreed source type, Micromix produces a
musically convincing result that is approximately 70–80% complete and exports
the components needed to finish it in Logic.

**Stop condition:** do not add a timeline, mixer, detailed automation, or
inferior duplicate of Logic Stem Splitter. An automatic reference finish is in
scope; a user-controlled mastering environment is not.

## Phase 5 — Reliable transcription

**Goal:** retain audio-to-MIDI only where Micromix offers a dependable advantage
for polyphonic or multi-instrument material.

- [ ] Benchmark MuScriptor Small, Medium, and Large against the current Medium
      baseline and Logic's relevant audio-to-MIDI workflow.
- [ ] Score note accuracy, timing, instrument assignment, edit burden, runtime,
      VRAM, and failure behavior.
- [ ] Select one default production profile; expose Fast/Best only if both have
      distinct proven value.
- [ ] Improve MIDI output for the winning polyphonic and multi-instrument cases.
- [ ] Evaluate an auralized check mix as a fast validation aid.
- [ ] Add MusicXML only if a real notation handoff benefits from it.
- [ ] Remove controls or workflows that do not improve the dependable result.

**Exit gate:** the supported transcription cases are explicitly documented and
produce assets that take less correction than the available Logic workflow.

**Stop condition:** de-emphasize or remove Transcribe if no repeatable advantage
is demonstrated.

## Phase 6 — Workflow intelligence

**Goal:** use analysis to remove setup work without turning analysis into a
separate technical product.

- [ ] Retain time-ranged structure, rhythm, key, instrument activity, pace, and
      confidence only where a creative operation consumes them.
- [ ] Suggest useful Repaint regions from detected song structure.
- [ ] Prefill creative metadata while preserving explicit user overrides.
- [ ] Add one-action handoffs among Library, Reimagine, Vocal Swap, Vocal
      Improve, Mashup, and Transcribe.
- [ ] Add lightweight song grouping only if real asset branching has become hard
      to navigate.
- [ ] Keep analysis details compact and secondary to creating the next asset.

**Exit gate:** analysis measurably reduces repetitive setup in at least two
creative workflows without introducing a new editing surface.

## Explicitly out of scope

- LoRA or style-adapter training and controls
- Public web application, hosted service, accounts, collaboration, or sharing
- Recording, comping, waveform editing, or multitrack timelines
- Manual detailed pitch/timing correction, mixer channels, plugin racks,
  automation lanes, or user-controlled mastering
- Chord-track, tempo-map, or elastic-audio replacements for Logic
- Generic model playgrounds and expert inference parameter panels
- Automatic publishing, distribution, or rights-management workflows

Private voice creation may be considered only after Phase 2 conversion is
successful. If pursued, it will be a separate gated phase called **Create
Voice**, with dataset preparation, consent/ownership, training reliability, and
quality acceptance defined before implementation.

## Quality and delivery policy

Automated tests cover typed contracts, validation, state transitions,
persistence, recovery, checksums, provenance, and failure handling. Backend
changes are tested and deployed on `lts1`; native changes are tested headlessly
on the Mac.

Audio quality is a manual acceptance gate. Each model evaluation records the
input, pinned model revision, settings, output, runtime, peak VRAM when
available, artifacts, source preservation, and usefulness after import into
Logic. A model's feature list is not evidence that it belongs in Micromix.

No phase is complete until its implementation plan is finished, automated tests
pass, deployment verification succeeds when applicable, and the manual corpus
review passes.

## Next action

Design and execute **Phase 0 — Product-quality baseline**. Do not begin Phase 1
feature implementation until the baseline exit gate is recorded.
