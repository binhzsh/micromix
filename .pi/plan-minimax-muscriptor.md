# Plan: minimax + muscriptor inference stack

**Created:** 2026-08-17 16:35
**Status:** active
**Started:** —

## Goal

`micromix` runs as a Docker Compose backend with two API-callable inference services — MiniMax Music 3 (text/lyrics→song) and MuScriptor (audio→MIDI) — reachable from the native macOS/iOS app.

## Tasks

- [x] 1. Accept CC BY-NC license on HF for MuScriptor models + create/pass HF token (user action, needed before task 4)
- [x] 2. Write docker-compose.yml: `minimax-music3` (sglang-omni, CUDA, port 8900, model at /mnt/fast_pool/fast_models/micromix/minimax) + `muscriptor` (uvx serve, CUDA, port 8901, HF_TOKEN)
- [ ] 3. Download MiniMax Music 3 weights (~57 GB) to fast_pool; verify sglang-omni single-GPU colocation fits in 24 GB VRAM (free realify_minimax_h3 if needed)
- [x] 4. Add API shim (`micromix-api`) on 8902 and proxy routes for `/v1/audio/speech` and `/transcribe/midi`
- [x] 5. Document API contract for the native app (endpoints, params, job semantics) in README

## Notes

- MiniMax Music 3: 8B global LLM + 0.6B local LLM + Flow Matching DIT; official docs say 2 GPUs, cookbook documents single-GPU colocation via `CUDA_VISIBLE_DEVICES=0`. Risk: VRAM fit unverified on one 3090.
- MuScriptor: MIT code, CC BY-NC 4.0 weights (personal use OK, blocks commercial app release). medium (307M) default; large (1.4B) for accuracy.
- GPU is shared with realify stack + gpu-router arbiter (127.0.0.1:9999). Decide whether new services should call the arbiter like Maestro does, or just document "one heavy job at a time".
- Gaps vs Maestro: stem separation (separator/audiosep), mastering (matchering) — port later from /mnt/main_pool/apps/maestro/services/.
- Ports chosen 8900/8901 to avoid clashes (3000 web, 7860 realify, 8000 llamacpp-router, 9999 gpu-router).
