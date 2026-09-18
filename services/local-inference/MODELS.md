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
| MuScriptor | [`7f213afe`](https://github.com/muscriptor/muscriptor/tree/7f213afecf23bd6a1b8672aa223690ee9807cefb): `TranscriptionModel.load_model`, `transcribe_and_postprocess`, `MT3_FULL_PLUS_GROUP_NAMES` |
| MLX Audio | [`40b27a21`](https://github.com/Blaizzy/mlx-audio/tree/40b27a2157150bf87a1f25958f049bdcd0861235): MiniMax `Model.generate`; `SAMAudio`, `SAMAudioProcessor`, `save_audio`; Whisper `STTOutput.text` |
| MLX RVC | [`f2663353`](https://github.com/lextoumbourou/mlx-rvc/tree/f26633539f1aa935337d8ca5e96c78784698bd7a): `RVCPipeline.from_pretrained(model_path)`, `convert(index_path=...)` |

ACE Turbo selects `acestep-v15-xl-turbo` with eight steps; Quality selects `acestep-v15-xl-sft` with 50. Text and reference generation use the local `acestep-5Hz-lm-4B` planner on PyTorch MPS; cover and repaint disable planning. DiT uses the upstream Apple Silicon MLX acceleration where supported and MPS otherwise. Variations run serially with persisted unsigned 32-bit seed + offset, wrapping at 2^32. `source_strength` maps to `audio_cover_strength`; repaint passes both interval endpoints and `repaint_strength`. Reference audio feeds `reference_audio`, and cover/repaint feed `src_audio`; these are actual audio conditioning paths.

MuScriptor runs on MPS and returns MIDI bytes with the detected beat grid. Exact instrument group IDs are exposed through capabilities. `detect_tempo=true` is upstream's strict mode: a recording without a usable steady beat fails; false skips detection. Every input is decoded locally through ffmpeg to mono 16 kHz WAV, including M4A and MP3.

RVC loads the selected private `.pth` or `.safetensors` file and optional FAISS index, never a fixed public voice. The worker verifies submitted SHA-256 revisions immediately before loading. PyTorch is installed for `.pth` conversion. SAM returns both target and residual WAV files. MiniMax is an optional basic text/lyrics generator only; metadata controls and Reimagine requests are rejected. Its upstream duration limit is 360 seconds. The Whisper text helper correctly reads `STTOutput.text`; no speech transcription is used to approximate audio conditioning.

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

For MuScriptor, accept the model license on [MuScriptor medium](https://huggingface.co/MuScriptor/muscriptor-medium) and authenticate with `uvx hf auth login`. License acceptance and account authentication must be completed by the user. Its weights download on first manual transcription and are cached by upstream. `MICROMIX_MUSCRIPTOR_MODEL` can select `small`, `medium` (default), `large`, or a local checkpoint path. SAM uses `mlx-community/sam-audio-large`; optional MiniMax uses `mlx-community/MiniMax-Music3-mxfp8`. Their weights and RVC's ContentVec/RMVPE helpers download into the Hugging Face cache on first use. Private voice weights/indexes remain in the ignored data directory managed by the API.

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
`~/.cache/micromix/ace/checkpoints`; `mlx-community/sam-audio-large`;
`mlx-community/MiniMax-Music3-mxfp8`; the `lexandstuff` ContentVec, RMVPE, and
RVC helper repositories; and `MuScriptor/muscriptor-medium`. The local
`base.safetensors` private RVC voice is present. All public and approved model
caches resolve with `HF_HUB_OFFLINE=1`.
