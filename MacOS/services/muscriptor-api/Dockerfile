FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .

RUN --mount=type=cache,target=/root/.cache/pip \
    pip install --no-cache-dir -r requirements.txt

COPY main.py .

EXPOSE 8902

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8902"]
