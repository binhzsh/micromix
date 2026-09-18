#!/bin/bash
# Install libraries only. Model downloads and inference are separate manual steps.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SERVICE="$ROOT/services/local-inference"
ENGINE=all
DRY_RUN=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        --engine) ENGINE="${2:?--engine needs ace, muscriptor, mlx, or all}"; shift 2 ;;
        --dry-run) DRY_RUN=(--dry-run); shift ;;
        *) echo "Usage: $0 [--engine ace|muscriptor|mlx|all] [--dry-run]" >&2; exit 2 ;;
    esac
done
case "$ENGINE" in ace|muscriptor|mlx|all) ;; *) echo "Unknown engine: $ENGINE" >&2; exit 2 ;; esac
if [ "$(uname -s)" != Darwin ] || [ "$(uname -m)" != arm64 ]; then
    echo 'These runtimes require Apple Silicon macOS.' >&2; exit 1
fi
command -v uv >/dev/null || { echo 'Install uv first: brew install uv' >&2; exit 1; }
command -v ffmpeg >/dev/null || { echo 'Install ffmpeg first: brew install ffmpeg' >&2; exit 1; }
install_engine() {
    local kind="$1" env="$2"
    shift 2
    if [ ! -x "$env/bin/python" ]; then
        uv venv --python 3.12 "$env"
    fi
    uv pip install "${DRY_RUN[@]}" --python "$env/bin/python" "$@"
    echo "$kind worker interpreter: $env/bin/python"
}
if [ "$ENGINE" = ace ] || [ "$ENGINE" = all ]; then
    install_engine ace "$SERVICE/.venv-ace" \
        'ace-step @ git+https://github.com/ace-step/ACE-Step-1.5.git@ca1e85fe9430179831e6bc6be790c332190a3866' \
        'torch==2.10.0' 'torchaudio==2.10.0' 'torchvision==0.25.0' 'torchcodec==0.10.0'
fi
if [ "$ENGINE" = muscriptor ] || [ "$ENGINE" = all ]; then
    install_engine muscriptor "$SERVICE/.venv-muscriptor" \
        'muscriptor @ git+https://github.com/muscriptor/muscriptor.git@7f213afecf23bd6a1b8672aa223690ee9807cefb' \
        'torch==2.10.0' 'torchaudio==2.10.0'
fi
if [ "$ENGINE" = mlx ] || [ "$ENGINE" = all ]; then
    install_engine mlx "$SERVICE/.venv-mlx" \
        'mlx-audio[stt,sts] @ git+https://github.com/Blaizzy/mlx-audio.git@40b27a2157150bf87a1f25958f049bdcd0861235' \
        'mlx-rvc[index] @ git+https://github.com/lextoumbourou/mlx-rvc.git@f26633539f1aa935337d8ca5e96c78784698bd7a' \
        'torch==2.10.0' 'soundfile>=0.13'
fi
echo 'Library setup finished. No model weights were downloaded and no inference was run.'
echo 'See services/local-inference/MODELS.md before the manual model-download and acceptance steps.'
