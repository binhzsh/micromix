# Phase 0 Private Audio Evaluation

This evaluation establishes the release baseline for Micromix's currently
shipped Generate, Reference, Remix/Cover, Repaint, and Transcribe operations.
It records reproducible evidence without committing private source audio or
generated media.

## Prepare the private corpus

1. Copy `corpus-manifest.example.json` to
   `evaluations/private/corpus-manifest.json`.
2. Place user-owned sources under `evaluations/private/sources/`.
3. Replace manifest `source_path` values with the actual local paths.
4. Keep the anonymized case IDs. Change `operations` only when an operation is
   genuinely inapplicable to that source.
5. A single source may cover more than one category, but each manifest entry
   must state the category it represents.

Required categories are clean studio audio, a dense mastered mix, live or
noisy audio, expressive vocals, instrumental/polyphonic material, and a long
source.

The entire `evaluations/private/` tree is ignored by Git. Never force-add audio,
MIDI, generated output, lyrics, artist names, or identifying descriptions.

## Store results

Store generated audio and MIDI beneath:

```text
evaluations/private/results/COMMIT/OPERATION/CASE-ID/
```

For example, a reference result may live at:

```text
evaluations/private/results/763fb8c/reference/clean-studio/result.wav
```

The committed `results.md` contains only anonymized ratings, exact software
revisions, job/asset metadata, aggregate timing, failure behavior, and the
phase-gate decision.

## Comparison rules

- Use the same prompt, seed, preset, variation count, and operation-specific
  strength when comparing cases or rerunning after a fix.
- Preserve the first failed job as evidence. Do not silently replace it with a
  successful retry.
- Record whether a worker was cold or warm before the request.
- Verify checksum, output count, provenance, and terminal job state before
  judging audio quality.
- Score every applicable result with `scorecard.md`.
- Import selected WAV and MIDI outputs into Logic Pro and record whether they
  open, align, audition, and remain editable as expected.
- Listening and Logic checks are manual. Do not automate the active desktop.

## Standard directions

Use these fixed starting directions unless a source makes one nonsensical:

- Generate: `cinematic alternative pop, expressive dynamics, complete song`
- Reference: `preserve the musical identity, improve arrangement clarity`
- Remix/Cover: `transform into atmospheric electronic rock`
- Repaint: `create a coherent contrasting section with a clean transition`

Use seed `42042`, one variation, and Turbo for the first pass. Add a Quality
pass for Generate and any source transformation whose Turbo output scores below
the acceptance threshold.

## Failure classification

Assign every finding exactly one disposition:

- `release-blocking` — prevents trustworthy use and must be fixed in Phase 0.
- `phase-1-candidate` — useful workflow improvement that does not invalidate
  the baseline.
- `documented-limitation` — model behavior with a safe, repeatable workaround.
- `no-action` — subjective preference or non-recurring artifact.
