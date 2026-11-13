# Local model runtimes

All rendering stays on this Mac. The API launches one disposable Python process per job and terminates its process group on cancellation. Each worker accepts a JSON manifest and atomically writes `output_dir/result.json` only after every output exists. There is no networked endpoint, container dependency, or off-machine inference.

Workers set `HF_HUB_OFFLINE=1` before importing a model adapter. They therefore
use only cached artifacts and fail with a local setup error if an artifact is
missing; rendering never fetches a model from the network. Download or update
models only through an explicit setup command while online.

## Install libraries

From the repository root, to prepare isolated model environments:

```sh
brew install uv ffmpeg
bash scripts/setup-local-models.sh --engine all
```

Use `--engine ace`, `--engine muscriptor`, or `--engine mlx` to install separately. `--dry-run` resolves packages without installing them (it may create an empty Python environment and fetch package metadata/source). Setup installs libraries only, never model weights. ACE and MuScriptor use `.venv-ace` and `.venv-muscriptor`; MLX uses `.venv-mlx`. Do not combine these environments: ACE requires Transformers 4 while current MLX Audio requires Transformers 5. PyTorch/audio/vision versions are kept together using the versions in ACE's upstream lockfile. The sidecar's `uv sync` manages only the API environment; model setup leaves that environment untouched.

On 2026-09-18, all three isolated library environments were installed on the
development Mac. Their documented import preflights passed, ACE and MuScriptor
reported MPS available, and a temporary loopback sidecar returned healthy
capabilities. No model weights were downloaded and no inference was run; these
checks do not establish model compatibility or audio quality.

## Reviewed upstream APIs

The installer pins these exact Git revisions; adapters were checked against these sources:

| Engine | Revision and API |
| --- | --- |
| ACE-Step | [`ca1e85fe`](https://github.com/ace-step/ACE-Step-1.5/tree/ca1e85fe9430179831e6bc6be790c332190a3866): `AceStepHandler.initialize_service`, `LLMHandler.initialize`, `GenerationParams`, `GenerationConfig`, `generate_music` |
| MuScriptor | v0.4.0 [`8a1ef886`](https://github.com/muscriptor/muscriptor/tree/8a1ef88672cc23c26619adaff37ec48d82c0b906): `TranscriptionModel.load_model`, `transcribe_and_postprocess`, `MT3_FULL_PLUS_GROUP_NAMES` |
| MLX Audio | [`606b3b27`](https://github.com/Neywa-Labs/mlx-audio/tree/606b3b27509f9c2c055a563eb79db7d6020a4bb4): MiniMax `Model.generate`; `SAMAudio`, `SAMAudioProcessor`, `save_audio`; Whisper `STTOutput.text`. Version metadata is 0.6.5, but this exact revision includes the later MiniMax chunk-vocoder memory fix. |
| MLX RVC | [`f2663353`](https://github.com/lextoumbourou/mlx-rvc/tree/f26633539f1aa935337d8ca5e96c78784698bd7a): `RVCPipeline.from_pretrained(model_path)`, `convert(index_path=...)` |

ACE Turbo selects `acestep-v15-xl-turbo` with eight steps; Quality selects `acestep-v15-xl-sft` with 50. Text and reference generation use the local `acestep-5Hz-lm-4B` planner on PyTorch MPS; cover and repaint disable planning. DiT uses the upstream Apple Silicon MLX acceleration where supported and MPS otherwise. Variations run serially with persisted unsigned 32-bit seed + offset, wrapping at 2^32. `source_strength` maps to `audio_cover_strength`; repaint passes both interval endpoints and `repaint_strength`. Reference audio feeds `reference_audio`, and cover/repaint feed `src_audio`; these are actual audio conditioning paths.

MuScriptor runs on MPS and returns MIDI bytes with the detected beat grid. v0.4.0's default `ExportOptions` automatically writes a tempo map for a nonsteady beat grid without quantizing note onsets. Micromix leaves `export` unset to retain those defaults; its call does not use the removed `quantize` keyword. Exact instrument group IDs are exposed through capabilities. `detect_tempo=true` is upstream's strict mode: a recording without a usable steady beat fails; `false` skips detection, and `best-effort` is forwarded to MuScriptor for its fallback behavior. Every input is decoded locally through ffmpeg to mono 16 kHz WAV, including M4A and MP3.

RVC loads the selected private `.pth` or `.safetensors` file and optional FAISS index, never a fixed public voice. The worker verifies submitted SHA-256 revisions immediately before loading. PyTorch is installed for `.pth` conversion. SAM returns both target and residual WAV files. The published SAM large config specifies a 1536-wide, 12-layer transformer while its large checkpoint has 2816-wide, 22-layer weights. The adapter recognizes that checkpoint and corrects the architecture in memory, then validates required parameter shapes before loading; incompatible or incomplete checkpoints fail instead of silently producing random-weight output. Model loading, separation quality and memory requirements still require manual validation on the target Mac. MiniMax is an optional basic text/lyrics generator only; metadata controls and Reimagine requests are rejected. Its upstream duration limit is 360 seconds. The Whisper text helper correctly reads `STTOutput.text`; no speech transcription is used to approximate audio conditioning.

## 2026-11-11 engine upgrade

- ACE and MLX worker environments pin both `mlx==0.32.4` and `mlx-metal==0.32.4`. This includes Metal deadlock and M1/M2 attention fixes; speed and memory improvements are not yet measured on the private corpus.
- MuScriptor moves from 0.3.0 to 0.4.0 for corrected tempo-map MIDI export. The medium checkpoint is unchanged.
- MLX Audio moves from `40b27a21` to exact revision `606b3b27`, not the older v0.6.5 release tag. Its [MiniMax fix](https://github.com/Neywa-Labs/mlx-audio/pull/1172) evaluates each vocoder chunk before building the next, avoiding deferred graphs accumulating over the song. Upstream's memory measurements use MXFP4, not this app's MXFP8 weights; do not assume the same peak memory.
- ACE-Step and MLX-RVC source pins, all model weights, the API environment, and native app are unchanged. Transformers remain isolated (ACE 4.57.6; MLX 5.17.0), and the matched PyTorch stack stays at 2.10.0.

Install or reproduce with `bash scripts/setup-local-models.sh --engine all`. Workers are disposable and use the updated environments on their next job. Restart the sidecar after updating adapter revision constants, once no jobs are queued or running. Audio-quality acceptance remains manual; no real-model inference is part of the automated upgrade checks.

### Upgrade verification

On 2026-11-11, `bash scripts/setup-local-models.sh --engine all` installed the above pins on the M2 Max development Mac. Only MLX/Metal changed in ACE; only MuScriptor changed in its environment; MLX/Metal and MLX Audio changed in the MLX environment. `uv pip check` passed for all three worker environments. Offline ACE, SAM/T5, MiniMax, and RVC imports and adapter-facing API signatures passed; ACE reported MPS available. The installed MiniMax implementation contains per-chunk `mx.eval(waves[-1])`.

From `services/local-inference`:

```sh
.venv/bin/python -m unittest discover -s tests -v
HF_HUB_OFFLINE=1 HF_HUB_DISABLE_TELEMETRY=1 .venv-muscriptor/bin/python -m unittest discover -s tests -p test_engines.py -v
```

The API suite passed 51 tests with one installed-engine test skipped (52 discovered). The MuScriptor environment passed all 17 engine tests, including the real synthetic-event MIDI exporter: variable tempo changes, unquantized onset timing, and missing-grid fallback, without loading weights or running a detector. Existing Starlette/httpx, PyWorld/pkg_resources, and optional ACE training warnings remain; no new dependency conflicts were reported. The idle LaunchAgent was restarted and `bash scripts/smoke-test.sh` passed with all five model markers ready. Marker readiness does not prove inference. Native source/API contracts were not changed and native tests were not rerun.

### Manual acceptance still required

The sidecar is already running; no native rebuild is needed for these engine-only changes. To reproduce the health check from the repository root, run `bash scripts/smoke-test.sh`. For a deliberate real ten-second MiniMax render, the user may run `RUN_GENERATION=1 bash scripts/smoke-test.sh` (this is inference, not part of the automated checks above).

In the native app, manually check:

1. Generate fixed-seed ACE Turbo and Quality; listen for English/Vietnamese intelligibility and regressions. Exercise reference/remix/repaint.
2. Transcribe an unsteady performance with best-effort tempo; import the MIDI into Logic and verify tempo changes, bar alignment, and note timing. Compare tempo disabled.
3. Generate a 30-second and a longer MiniMax MXFP8 result; listen and record peak unified memory. Do not infer MXFP8 memory from upstream MXFP4 benchmarks.
4. Split a known song into target/residual and convert a prepared vocal with the existing private RVC voice; check preservation and artifacts.

Record outcomes privately before accepting audio quality or performance. No model weights were changed or downloaded during this upgrade.

## Download models manually

Weights are cached outside Git. The following explicit commands download ACE's shared components, XL models, and planner, without running inference:

```sh
export MICROMIX_ACE_ROOT="$HOME/.cache/micromix/ace"
export ACESTEP_CHECKPOINTS_DIR="$MICROMIX_ACE_ROOT/checkpoints"
services/local-inference/.venv-ace/bin/acestep-download --dir "$ACESTEP_CHECKPOINTS_DIR"
services/local-inference/.venv-ace/bin/acestep-download --dir "$ACESTEP_CHECKPOINTS_DIR" --skip-main --model acestep-v15-xl-turbo
services/local-inference/.venv-ace/bin/acestep-download --dir "$ACESTEP_CHECKPOINTS_DIR" --skip-main --model acestep-v15-xl-sft
services/local-inference/.venv-ace/bin/acestep-download --dir "$ACESTEP_CHECKPOINTS_DIR" --skip-main --model acestep-5Hz-lm-4B
```

These are substantial downloads. Default ACE paths match the exports above; custom paths must also be configured in the sidecar's launch environment. Upstream ACE may download missing shared/DiT files at first initialization; the required 4B planner must be explicitly downloaded.

For MuScriptor, accept the model license on [MuScriptor medium](https://huggingface.co/MuScriptor/muscriptor-medium) and authenticate with `uvx hf auth login`. License acceptance and account authentication must be completed by the user. Its weights are read from the local model store and never fetched at render time. `MICROMIX_MUSCRIPTOR_MODEL` can select `small`, `medium` (default), `large`, or a local checkpoint path. SAM loads `~/models/sam-audio-large` and optional MiniMax loads `~/models/MiniMax-Music3-mxfp8` from the local model store (`MICROMIX_MODELS_DIR` overrides the root); both directories hold complete HF snapshots with config and all weight shards. RVC's ContentVec/RMVPE helpers load from `~/models/mlx-contentvec` and `~/models/mlx-rmvpe` in the local model store. MuScriptor weights resolve from `~/models/muscriptor-<size>` in the local model store (a size keyword or an explicit path still works). Private voice weights/indexes remain in the ignored data directory managed by the API.

### Lyrics transcription (MLX Whisper)

`POST /v1/jobs/lyrics-transcription` accepts multipart `audio_file` and queues a
separate durable job; it does not change the MIDI transcription endpoint. The
worker decodes to mono 16 kHz WAV and writes UTF-8 `text/plain` lyrics. Empty
recognition fails with a no-lyrics-or-speech error. Whisper can hallucinate or
miss sung words; results require manual review and are not a guarantee that
lyrics exist.

Provision the MLX-compatible snapshot explicitly while online, from the repo root:

```sh
uvx hf download mlx-community/whisper-large-v3-turbo-asr-fp16 --local-dir "$HOME/models/whisper-large-v3-turbo-asr-fp16"
```

The default directory is `$MICROMIX_MODELS_DIR/whisper-large-v3-turbo-asr-fp16` (model store
root defaults to `~/models`). Set `MICROMIX_WHISPER_MODEL` in the sidecar's
launch environment to select another local snapshot directory. Restart the
sidecar after changing its environment. Health reports `whisper` as `unavailable`
when the MLX library environment is missing, `weights_missing` when its
`config.json` or `model.safetensors` is missing, and otherwise `ready`. These
are filesystem/dependency checks, not inference or quality checks; incomplete
or incompatible snapshots may still fail at load. Jobs never download weights.

## Preflight and acceptance

After library installation, these imports check runtime availability without loading model weights:

```sh
services/local-inference/.venv-ace/bin/python -c 'from acestep.handler import AceStepHandler; from acestep.llm_inference import LLMHandler; from acestep.inference import GenerationParams; import torch; print(torch.backends.mps.is_available())'
services/local-inference/.venv-muscriptor/bin/python -c 'from muscriptor import TranscriptionModel; import torch; print(torch.backends.mps.is_available())'
services/local-inference/.venv-mlx/bin/python -c 'from mlx_rvc import RVCPipeline; from mlx_audio.sts import SAMAudio, SAMAudioProcessor; from mlx_audio.music.utils import load_model'
```

The exact worker commands are below. Replace `/absolute/manifest.json` with a runtime-created manifest or an equivalent private test file. Run commands from the repository root; the direct script supports any working directory without `PYTHONPATH`:

```sh
# ACE text/reference/cover/repaint
services/local-inference/.venv-ace/bin/python services/local-inference/local_inference/worker.py /absolute/manifest.json
# MuScriptor
services/local-inference/.venv-muscriptor/bin/python services/local-inference/local_inference/worker.py /absolute/manifest.json
# RVC, SAM, optional MiniMax
services/local-inference/.venv-mlx/bin/python services/local-inference/local_inference/worker.py /absolute/manifest.json
```

Module invocation also works from `services/local-inference`: `.venv-ace/bin/python -m local_inference.worker /absolute/manifest.json` (select the matching interpreter).

Manifest shape:

```json
{"operation":"generation","parameters":{"preset":"turbo","prompt":"quiet piano","lyrics":null,"seed":42,"seeds":[42],"variation_count":1,"duration_seconds":30},"inputs":[],"output_dir":"/absolute/private/output"}
```

Heavy inference, listening, performance, and native UI acceptance are manual gates under AGENTS.md. Check a fixed-seed Turbo/Quality render and four variations; reference influence; cover source strength; a repaint interval with preserved surrounding music; instrument-filtered MIDI with tempo on/off from WAV/M4A/MP3; two distinct private voices and an index; both SAM stems; queued/running cancellation and restart recovery. Inspect `result.json` and listen/import outputs. Lightweight adapter tests prove parameter propagation and output publication only, not model quality or accepted feature parity.

## Current development-Mac cache

On 2026-09-18, the following public artifacts were downloaded and checked for
offline cache use: ACE-Step shared bundle, XL Turbo, XL SFT, and 4B planner in
`~/.cache/micromix/ace/checkpoints`; `~/models/sam-audio-large`;
`~/models/MiniMax-Music3-mxfp8`; the `lexandstuff` ContentVec, RMVPE, and
RVC helper repositories; and `MuScriptor/muscriptor-medium`. The local
`base.safetensors` private RVC voice is present. All public and approved model
caches resolve with `HF_HUB_OFFLINE=1`.
