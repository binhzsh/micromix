#!/usr/bin/env bash
set -euo pipefail

MUSIC_ENGINE_URL=${MUSIC_ENGINE_URL:-http://localhost:8902}

echo "==> API health"
curl -sS "$MUSIC_ENGINE_URL/health" | sed 's/.*/&/'

echo
echo "==> Quick MiniMax smoke call (text only, 8-12 seconds response expected on a warm cache)"
curl -X POST "$MUSIC_ENGINE_URL/v1/audio/speech" \
  -H "Content-Type: application/json" \
  -d '{"input":"Lo-fi warm 4/4 groove, electric bass and drums, no vocals."}' \
  --output /tmp/minimax-smoke.wav \
  --silent --show-error --fail
echo "saved /tmp/minimax-smoke.wav"

echo
echo "Smoke complete. Set MUSIC_ENGINE_URL=http://host:port to target a different endpoint."

