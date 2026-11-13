# Historical record: Generation progress and lyrics transcription

**Superseded 2026-11-12:** Active follow-up instructions now live in [PLAN.md](PLAN.md), tasks 9 and 12. Keep the implementation/verification history below; do not execute this file as a parallel backlog. References below to preserving the old PLAN.md describe the earlier session, not current agent instructions.

## Context
User requested live generation progress and transcription of sung lyrics from audio. User chose an Apple Silicon MLX Whisper model, accepting a model download. Existing `PLAN.md` is a pre-existing uncommitted change and must remain untouched. Whisper produces an unverified draft, not ground truth; actual English/Vietnamese singing quality requires user-led evaluation.

## Tasks
- [x] 1. Add honest generation progress UI without inventing a percentage; verify headless.
  - Status: done; indeterminate bar added because jobs do not publish intermediate percentages; full native suite passed.
- [x] 2. Add local lyrics-transcription sidecar job with offline checkpoint configuration, output and tests.
  - Status: done; 56 tests run, one skipped; compatible default model loads offline.
- [x] 3. Integrate lyrics transcription and persistent text results into the macOS app, preserving MIDI and audio behavior.
  - Status: done; full native suite passed 156 tests; visual checks remain a manual gate.
- 4. User-led singing-quality and visual acceptance — **transferred, not completed**, to `PLAN.md` task 12.
  - English, Vietnamese, instrumental-only and noisy audio remain unverified after rebuilding the app.

## Log
- 2026-11-12: Confirmed prior `PLAN.md` change is intentional and preserved; fetch and fast-forward pull were already up to date. User chose transcription of existing vocals and MLX Whisper.
- 2026-11-12: The small-mlx snapshot uses weights.npz and strict model loading rejects an extra alignment_heads parameter. The MLX Audio README's `whisper-large-v3-turbo-asr-fp16` checkpoint was downloaded and loaded successfully with strict offline loading; idle sidecar restarted and Whisper health reports ready. No actual transcription or visual/audio acceptance was performed. The unused small snapshot remains in `~/models/whisper-small-mlx`.
