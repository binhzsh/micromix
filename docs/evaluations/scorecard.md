# Private model-evaluation scorecard

Use one private record per source, operation, model revision and settings. Keep source audio, outputs and completed records in the ignored private evaluation area; do not commit them. Run inference, listening and Logic checks manually. A service health check or automated test is not an audio-quality result.

## Corpus coverage

Review the private corpus manifest and add source material only with appropriate rights. The current manifest lists clean studio, expressive Vietnamese vocal, dense mastered mix, long source and polyphonic cases. It records missing English vocals, live/noisy audio and instrumental-only material. Verify each file's actual characteristics before claiming coverage; one recording may cover multiple categories but does not establish diversity.

## Record for each run

- Date, private case ID, language and source type; app commit/working-tree state and sidecar revision.
- Operation, source identity/checksum, model and weight revisions, preset, seed, language intent and other relevant settings.
- Output identifiers/paths kept privately, duration, elapsed time, peak unified memory if measurable, and any recovery/cancellation errors.
- Logic import: imported successfully? Components aligned and usable? Extra editing needed?
- Scores (0–5, with 0 = unusable and 5 = excellent): overall creative usefulness, source/performance preservation, absence of artifacts, intelligibility, identity and pitch/expression preservation where applicable, and timing/note accuracy for MIDI.
- For Vietnamese vocals, note whether lexical tones remain intelligible; for English, note lyric intelligibility. Mark inapplicable fields N/A rather than treating them as passes.
- Specific audible or visible defects, comparison with source or Logic workflow, and a pass/fail/defer decision with rationale.

## Decision rule

Record individual outcomes, including failures. A feature is accepted only against the roadmap's phase-specific exit criteria after its relevant corpus, reliability and Logic checks are complete. Reject or defer enhancements that degrade musical expression or fail the stated quality bar.
