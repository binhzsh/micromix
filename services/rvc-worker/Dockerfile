FROM nvidia/cuda:12.4.1-cudnn-runtime-ubuntu22.04

ARG RVC_COMMIT=81eed5e8f68b6bed1789f682fe78cdd324495afc

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1

RUN apt-get update \
    && apt-get install -y --no-install-recommends python3 python3-pip ffmpeg git \
    && rm -rf /var/lib/apt/lists/*

RUN git clone https://github.com/RVC-Project/Retrieval-based-Voice-Conversion-WebUI.git /opt/rvc \
    && cd /opt/rvc \
    && git checkout "${RVC_COMMIT}" \
    && python3 -m pip install --break-system-packages -r requirements.txt

WORKDIR /app
COPY requirements.txt .
RUN python3 -m pip install --break-system-packages -r requirements.txt
COPY app.py .

ENV RVC_ROOT=/opt/rvc \
    ASSET_ROOT=/data \
    VOICE_ROOT=/voices

CMD ["python3", "-m", "uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8910"]
