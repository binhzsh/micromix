# Model Capability Gap Analysis

This report reflects the current on-disk implementation, including the present workspace changes that complete native Reimagine and job-reattachment work.

## ACE-Step 1.5 XL Turbo — 8 steps

### Currently implemented

- Text/prompt-to-music and lyrics-to-song.
- Reference-audio generation.
- Remix/Cover and time-range Repaint.
- Duration, BPM, key, time signature, source strength, and repaint strength controls.
- Deterministic seeds and one to four variations.
- WAV output, cancellation, recovery, provenance, and local-library import.
- Turbo/Quality selection is wired in [`services/micromix-api/micromix_api/adapters.py`](services/micromix-api/micromix_api/adapters.py); native Reimagine controls are in [`MacOS/sources/Reimagine/ReimagineViewModel.swift`](MacOS/sources/Reimagine/ReimagineViewModel.swift).

### Model capabilities not implemented

- Output-format selection: FLAC, MP3, Opus, AAC, and WAV32.
- Explicit vocal-language selection and broader multilingual UX.
- Advanced audio-code reuse and variant workflows.
- User controls for guidance, sampling, inference steps, language-model behavior, and other low-level parameters.
- LoRA/LoKr loading and private style training.
- The Generate screen lacks seed, variations, BPM, key, and time-signature controls even though Reimagine and the API support them.
- Lego, Extract, and Complete are unavailable with Turbo; these require an appropriate non-Turbo model.

Upstream reference: [ACE-Step musician guide](https://github.com/ace-step/ACE-Step-1.5/blob/main/docs/en/ace_step_musicians_guide.md)

## ACE-Step 1.5 XL SFT / Quality — 50 steps

### Currently implemented

- The same implemented workflows and controls as Turbo, using slower 50-step inference.
- Text/lyrics generation, reference generation, Remix, Repaint, variations, deterministic seeds, musical metadata, durable jobs, and provenance.
- Checkpoint configuration is pinned in [`docker-compose.yml`](docker-compose.yml).

### Model capabilities not implemented

- Lego: generate or add selected instrumental layers.
- Extract: semantic isolation of vocals or selected instruments.
- Complete/continuation: create accompaniment for partial tracks or vocals.
- Output-format choice, vocal-language control, audio captioning, semantic-code reuse, LoRA inference/training, and expert sampling controls.
- No dedicated “extend this song” or stem-aware native workflow.
- No production stem or session-bundle export. ACE-Step itself produces rendered audio rather than MIDI or DAW sessions.

Upstream reference: [ACE-Step inference documentation](https://github.com/ace-step/ACE-Step-1.5/blob/main/docs/en/INFERENCE.md)

## ACE-Step 5Hz LM 4B planner

### Currently implemented

- Loaded for both ACE checkpoints.
- Thinking is enabled automatically for text and reference generation, but disabled for Remix and Repaint.
- Provides internal generation planning without direct user configuration.
- Implementation: [`services/micromix-api/micromix_api/adapters.py`](services/micromix-api/micromix_api/adapters.py).

### Model capabilities not implemented

- Audio-to-caption and music understanding.
- Automatic prompt expansion and reformatting.
- Automatic lyrics and musical-metadata suggestions.
- Thinking toggle, planning-language selection, and generated-plan inspection.
- No standalone Analyze fallback using ACE understanding capabilities.

## MuScriptor 0.3.0 — Medium model

### Currently implemented

- Polyphonic and multi-instrument audio-to-MIDI.
- Optional filtering across 36 instrument groups.
- Optional or best-effort tempo detection and beat-grid-adjusted MIDI.
- Broad input decoding through FFmpeg.
- Durable jobs, cancellation/recovery, and MIDI library import.
- Model size is server-configurable but defaults to `medium`; see [`docker-compose.yml`](docker-compose.yml) and [`services/muscriptor-worker/muscriptor_worker/main.py`](services/muscriptor-worker/muscriptor_worker/main.py).

### Model capabilities not implemented

- Small or large model selection in the app.
- Event-stream, JSON, and JSONL output.
- MusicXML export.
- Full-score or per-instrument PDF/tab exports.
- Auralized transcription check mix.
- Sampling-temperature and beam-search controls.
- Quantized MIDI and richer tempo/score options.
- Multiple output assets instead of one MIDI file.
- No benchmark or evaluation proving where it outperforms Logic Flex Pitch.

Upstream reference: [MuScriptor implementation](https://github.com/muscriptor/muscriptor/blob/main/muscriptor/main.py)

## Apple Music Understanding — on-device, macOS 27+

### Currently implemented

- File duration.
- Aggregate BPM, first detected key, and detected instrument names.
- BPM and key can prefill ACE reference-generation controls.
- The macOS 26 fallback provides duration only.
- Implementation: [`MacOS/sources/Audio/LocalMusicAnalyzer.swift`](MacOS/sources/Audio/LocalMusicAnalyzer.swift).

### Framework capabilities not implemented

- Beat timestamps and bar boundaries.
- Time-ranged key changes.
- Detailed instrument activity and intensity over time.
- Song structure: sections, segments, and phrases.
- Pace and energy analysis.
- Integrated, short-term, momentary, and peak loudness.
- Incremental or streaming analysis and confidence/provenance retention.
- Repaint-range suggestions derived from song structure.

Apple exposes six major analysis dimensions—rhythm, key, structure, pace, instrument activity, and loudness—but Micromix currently requests only rhythm, key, and instrument activity and stores aggregate summaries.

Upstream reference: [Apple Music Understanding documentation](https://developer.apple.com/documentation/musicunderstanding)
