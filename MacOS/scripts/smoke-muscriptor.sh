#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" = "" ]; then
  echo "Usage: $0 /path/to/audio_file.mp3" >&2
  exit 1
fi

AUDIO_FILE="$1"
MUSIC_ENGINE_URL=${MUSIC_ENGINE_URL:-http://localhost:8902}

echo "==> MuScriptor smoke call: $AUDIO_FILE"
curl -X POST "$MUSIC_ENGINE_URL/transcribe/midi" \
  -F "audio_file=@$AUDIO_FILE" \
  -F "instruments=acoustic_guitar" \
  --output /tmp/muscriptor-smoke.mid \
  --silent --show-error --fail
echo "saved /tmp/muscriptor-smoke.mid"

