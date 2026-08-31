#!/usr/bin/env bash
set -euo pipefail

MICROMIX_URL=${MICROMIX_URL:-http://localhost:8902}

echo "==> Gateway health"
curl --fail --silent --show-error "$MICROMIX_URL/v1/health"
echo
echo "==> Capabilities"
curl --fail --silent --show-error "$MICROMIX_URL/v1/capabilities"
echo

if [ "${RUN_GENERATION:-0}" != "1" ]; then
  echo "Cold smoke complete. Set RUN_GENERATION=1 for a real 10-second ACE-Step job."
  exit 0
fi

response=$(curl --fail --silent --show-error \
  -X POST "$MICROMIX_URL/v1/jobs/generation" \
  -H 'Content-Type: application/json' \
  -d '{"prompt":"warm lo-fi drums and electric piano, instrumental","preset":"turbo","duration_seconds":10}')
job_id=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])' <<<"$response")
echo "submitted $job_id"

while true; do
  response=$(curl --fail --silent --show-error "$MICROMIX_URL/v1/jobs/$job_id")
  state=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["state"])' <<<"$response")
  echo "state=$state"
  case "$state" in
    succeeded)
      asset_url=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["asset"]["download_url"])' <<<"$response")
      curl --fail --silent --show-error "$MICROMIX_URL$asset_url" --output /tmp/micromix-smoke.wav
      echo "saved /tmp/micromix-smoke.wav"
      break
      ;;
    failed|cancelled)
      echo "$response" >&2
      exit 1
      ;;
  esac
  sleep 2
done

