ARG CUDA_VERSION=12.8.1
FROM nvidia/cuda:${CUDA_VERSION}-runtime-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive LANG=C.UTF-8 LC_ALL=C.UTF-8
RUN apt-get update && apt-get install -y --no-install-recommends \
        software-properties-common build-essential git curl libsndfile1 libsndfile1-dev \
        ffmpeg libffi-dev libssl-dev \
    && add-apt-repository ppa:deadsnakes/ppa \
    && apt-get update \
    && apt-get install -y --no-install-recommends python3.11 python3.11-dev python3.11-venv \
    && rm -rf /var/lib/apt/lists/*

COPY --from=ghcr.io/astral-sh/uv:0.7.22 /uv /uvx /bin/
ARG ACESTEP_COMMIT=dce621408bee8c31b4fcf4811682eb9359e1bc94
WORKDIR /app
RUN git init \
    && git remote add origin https://github.com/ace-step/ACE-Step-1.5.git \
    && git fetch --depth 1 origin "${ACESTEP_COMMIT}" \
    && git checkout --detach FETCH_HEAD \
    && uv sync --frozen --no-dev --python python3.11 \
    && mkdir -p /app/checkpoints /app/gradio_outputs /app/output
COPY supervisor.py /app/supervisor.py

ENV ACESTEP_CONFIG_PATH=acestep-v15-xl-turbo \
    ACESTEP_CONFIG_PATH2=acestep-v15-xl-sft \
    ACESTEP_LM_MODEL_PATH=acestep-5Hz-lm-4B \
    ACESTEP_LLM_BACKEND=pt \
    ACESTEP_DOWNLOAD_SOURCE=huggingface \
    TOKENIZERS_PARALLELISM=false
EXPOSE 8001
CMD ["/app/.venv/bin/uvicorn", "supervisor:app", "--host", "0.0.0.0", "--port", "8001"]
