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

TS_AUTHKEY_VALUE="$(sed -n 's/^TS_AUTHKEY=//p' .env | tail -n 1)"
JUPYTER_TOKEN_VALUE="$(sed -n 's/^JUPYTER_TOKEN=//p' .env | tail -n 1)"
MINIO_PASSWORD_VALUE="$(sed -n 's/^MINIO_ROOT_PASSWORD=//p' .env | tail -n 1)"
[[ -n "$TS_AUTHKEY_VALUE" && "$TS_AUTHKEY_VALUE" != *REPLACE* ]] || {
  echo "ERROR: Set TS_AUTHKEY in .env to a reusable auth key tagged tag:spark-lakehouse-mcp."
  exit 1
}
[[ "$JUPYTER_TOKEN_VALUE" != "replace-with-a-long-random-token" && -n "$JUPYTER_TOKEN_VALUE" ]] || {
  echo "ERROR: Replace the sample JUPYTER_TOKEN in .env."
  exit 1
}
[[ "$MINIO_PASSWORD_VALUE" != "replace-with-a-strong-unique-password" && -n "$MINIO_PASSWORD_VALUE" ]] || {
  echo "ERROR: Replace the sample MINIO_ROOT_PASSWORD in .env."
  exit 1
}

mkdir -p notebooks retail lakehouse/{raw,bronze,silver,gold,checkpoints}
touch notebooks/.gitkeep retail/.gitkeep lakehouse/bronze/.gitkeep lakehouse/silver/.gitkeep lakehouse/gold/.gitkeep
docker compose config --quiet
echo "Setup checks passed. Run ./scripts/up.sh to start the complete stack."
