FROM python:3.12-slim-bookworm

COPY --from=ghcr.io/astral-sh/uv:0.7.22 /uv /uvx /bin/
WORKDIR /app
COPY pyproject.toml uv.lock ./
RUN uv sync --frozen --no-dev
COPY micromix_api ./micromix_api

EXPOSE 8902
CMD ["/app/.venv/bin/uvicorn", "micromix_api.main:app", "--host", "0.0.0.0", "--port", "8902"]
