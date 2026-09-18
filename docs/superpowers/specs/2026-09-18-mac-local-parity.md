# Mac-local feature parity

Restore features implemented in server baseline 8099981, plus complete local vocal conversion and stem workflows already present in the sidecar. Remain a private, solo-user native Mac app. No lts1, Docker, remote inference or web UI.

## Design

A loopback FastAPI service persists jobs, assets, checksums, ordered inputs/outputs and public provenance in SQLite. One dispatcher launches one disposable child process per render. Child termination cancels running inference and releases model memory; queued cancellation prevents launch. Cancelled terminal state cannot be overwritten. On service restart requeue interrupted jobs with their fixed seeds and inputs; publish outputs atomically only after success. Retain active-job assets; prune old terminal records and unreferenced assets after seven days. Stream uploads with a 200 MiB limit.

Local ACE-Step XL Turbo/SFT replaces the reduced MiniMax approximation for the parity workflow: text/lyrics, real reference audio, cover, repaint, BPM/key/meter/language, seed and 1–4 variations. Local MuScriptor restores instrument filtering and beat-grid-aware MIDI. Keep MiniMax available as an explicitly limited optional generation engine. Model adapters run only on local CPU/Metal/MLX. Pin upstream revisions and provide installation/preflight commands without downloading or evaluating models automatically.

MLX-RVC loads the user's resolved private voice model and optional index, records a content revision, and returns a vocal WAV. SAM-Audio returns target/residual WAV assets. Whisper extraction reads STTOutput.text when the optional MiniMax path needs it. Voice files stay under an ignored private root, validated against traversal. Native Vocal Swap and Stem Split reuse upload, durable jobs, recovery, Library and playback rather than creating another asset store.

Restore native controls and exact supported request values. Capabilities include canonical presets, instrument groups and available voice IDs. Missing dependencies fail with a concrete local setup instruction; do not silently replace a requested model operation with a weaker approximation.

## Verification

Regression tests use actual SQLite, temporary assets and lightweight disposable subprocesses. Adapter tests replace heavy model loading only, exercising parameter propagation and ordered outputs. Run the full headless Swift suite and local backend contract suite. Heavy model execution, visual acceptance, performance and listening require the user's manual results per AGENTS.md; code completion is distinct from accepted model-quality parity.
