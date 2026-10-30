#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."

command -v docker >/dev/null 2>&1 || { echo "ERROR: Docker CLI not found. Install Docker Engine/Desktop."; exit 1; }
docker compose version >/dev/null 2>&1 || { echo "ERROR: Docker Compose v2 is required."; exit 1; }

if [[ ! -f .env ]]; then
  cp .env.example .env
  echo "Created .env from .env.example."
  echo "Edit .env and set JUPYTER_TOKEN, MINIO_ROOT_PASSWORD and TS_AUTHKEY."
  read -r -p "Press Enter after editing .env to continue, or Ctrl+C to stop."
fi

set -a
. ./.env
set +a
[[ "${TS_AUTHKEY:-}" != "tskey-auth-REPLACE_WITH_YOUR_TAGGED_KEY" && -n "${TS_AUTHKEY:-}" ]] || {
  echo "ERROR: Set TS_AUTHKEY in .env to a reusable auth key tagged tag:spark-lakehouse-mcp."
  exit 1
}
[[ "${JUPYTER_TOKEN:-}" != "replace-with-a-long-random-token" && -n "${JUPYTER_TOKEN:-}" ]] || {
  echo "ERROR: Replace the sample JUPYTER_TOKEN in .env."
  exit 1
}
[[ "${MINIO_ROOT_PASSWORD:-}" != "replace-with-a-strong-unique-password" && -n "${MINIO_ROOT_PASSWORD:-}" ]] || {
  echo "ERROR: Replace the sample MINIO_ROOT_PASSWORD in .env."
  exit 1
}

mkdir -p notebooks retail lakehouse/{raw,bronze,silver,gold,checkpoints}
touch notebooks/.gitkeep retail/.gitkeep lakehouse/bronze/.gitkeep lakehouse/silver/.gitkeep lakehouse/gold/.gitkeep
docker compose config --quiet
echo "Setup checks passed. Run ./scripts/up.sh to start the complete stack."
