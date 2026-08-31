FROM ghcr.io/astral-sh/uv:python3.12-bookworm

RUN apt-get update \
    && apt-get install -y --no-install-recommends ffmpeg \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY pyproject.toml uv.lock ./
RUN uv sync --frozen --no-dev
COPY muscriptor_worker ./muscriptor_worker

EXPOSE 8901
CMD ["/app/.venv/bin/uvicorn", "muscriptor_worker.main:app", "--host", "0.0.0.0", "--port", "8901"]
