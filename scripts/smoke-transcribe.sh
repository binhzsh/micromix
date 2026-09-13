#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" = "" ]; then
  echo "Usage: $0 /path/to/audio_file" >&2
  exit 1
fi

MICROMIX_URL=${MICROMIX_URL:-http://localhost:8902}
response=$(curl --fail --silent --show-error \
  -X POST "$MICROMIX_URL/v1/jobs/transcription" \
  -F "audio_file=@$1" \
  -F "detect_tempo=true")
job_id=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])' <<<"$response")
echo "submitted $job_id"

while true; do
  response=$(curl --fail --silent --show-error "$MICROMIX_URL/v1/jobs/$job_id")
  state=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["state"])' <<<"$response")
  case "$state" in
    succeeded)
      asset_url=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["asset"]["download_url"])' <<<"$response")
      curl --fail --silent --show-error "$MICROMIX_URL$asset_url" --output /tmp/micromix-smoke.mid
      echo "saved /tmp/micromix-smoke.mid"
      break
      ;;
    failed|cancelled)
      echo "$response" >&2
      exit 1
      ;;
  esac
  sleep 2
done
