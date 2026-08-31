# Micromix Phase 0 Quality Scorecard

Complete one scorecard for every applicable operation and corpus case. Higher
scores are always better. Record the first attempt, including failures, before
running a comparison or retry.

## Run identity

| Field | Recorded value |
| --- | --- |
| Date and timezone | |
| Evaluator | |
| Corpus case ID | |
| Vocal language | English / Vietnamese / mixed / instrumental |
| Operation | Generate / Reference / Remix / Repaint / Transcribe |
| Git commit (40 characters) | |
| Service image ID | |
| Model and revision | |
| Preset | Turbo / Quality / MuScriptor Medium |
| Seed | |
| Prompt/direction | |
| Variation count | |
| Operation strength/range | |
| Input duration | |
| Output duration | |
| Worker start state | cold / warm |
| Wall time | |
| Peak VRAM | unavailable or measured MiB |
| Terminal job state | succeeded / failed / cancelled / missing |
| Output count | |
| Checksum verified | yes / no / not applicable |
| Provenance verified | yes / no |
| Logic import verified | yes / no / not applicable |

## Anchored rating scale

Use whole numbers from 1 through 5. A score of 3 means the result is useful but
needs material correction. Do not reinterpret the direction for artifacts:
higher means fewer or less damaging artifacts.

| Score | Anchor |
| --- | --- |
| 1 | Unusable; failed intent or requires replacement rather than correction. |
| 2 | Major problems; some value is present but correction cost is excessive. |
| 3 | Useful after material correction; worth carrying into Logic. |
| 4 | Strong; needs ordinary finishing work rather than repair. |
| 5 | Immediately useful; only taste-driven or final-polish changes remain. |

## Shared ratings

| Dimension | 1–5 | Evidence |
| --- | ---: | --- |
| Creative usefulness | | Does this create an idea or asset worth keeping? |
| Source/intent preservation | | Does it retain the intended source identity or requested direction? |
| Language intelligibility | | Are English or Vietnamese words understandable and phrased naturally? |
| Vietnamese tone preservation | | For Vietnamese only: are lexical tones preserved well enough to retain meaning? |
| Musical coherence | | Are structure, harmony, rhythm, phrasing, and transitions convincing? |
| Artifact quality | | Are audible glitches, smearing, pumping, discontinuities, and synthetic artifacts acceptably low? |
| Edit burden | | How close is it to the 70–80% Micromix target before detailed Logic work? |
| Operational reliability | | Did submission, progress, recovery, download, checksum, and provenance behave predictably? |

## Operation-specific evidence

### Generate

- Does the result follow the requested style and instrumentation?
- Does it develop beyond a short loop?
- Are vocals and lyrics intelligible when requested?
- Does the ending feel intentional enough to edit or fade in Logic?

### Reference

- Is the reference influence recognizable without merely copying defects?
- Is the new result musically complete and independently useful?
- Do metadata constraints improve rather than destabilize the result?

### Remix/Cover

- Are melody, rhythm, or structure preserved to the intended degree?
- Is the requested transformation clear?
- Are vocals, transients, and dense sections stable?

### Repaint

- Is material outside the selected interval preserved?
- Are both edit boundaries continuous?
- Does the replacement section satisfy the new direction?
- Would the result require crossfade repair in Logic?

### Transcribe

Add these four ratings using the same 1–5 anchors:

| Dimension | 1–5 | Evidence |
| --- | ---: | --- |
| Note accuracy | | Correct pitches, omissions, and false notes. |
| Timing accuracy | | Onsets, durations, tempo interpretation, and drift. |
| Instrument assignment | | Correct grouping and practical track separation. |
| Correction burden | | Work required before the MIDI is creatively useful. |

## Gate calculation

An operation passes the baseline when all of these conditions hold:

- Every tested job reaches a terminal state and every successful asset imports.
- No checksum, reattachment, duplicate-import, or provenance failure occurs.
- Median creative usefulness is at least 3.
- Median edit-burden score is at least 3.
- No case receives an artifact score of 1 without a documented limitation or
  completed fix.
- The English and Vietnamese vocal subsets each have median language
  intelligibility of at least 3.
- The Vietnamese vocal subset has median tone preservation of at least 3.

Transcribe additionally requires median note accuracy, timing accuracy, and
correction burden of at least 3 for the cases Micromix claims to support.

## Finding disposition

Choose exactly one:

- `release-blocking`
- `phase-1-candidate`
- `documented-limitation`
- `no-action`

Record the evidence, safe workaround if one exists, and the follow-up commit or
roadmap item. Do not average away a data-loss, checksum, duplicate-import, or
provenance failure.
