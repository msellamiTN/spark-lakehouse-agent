#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."

if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: Docker CLI not found. Install Docker Desktop / Docker Engine."
  exit 1
fi
if ! docker compose version >/dev/null 2>&1; then
  echo "ERROR: Docker Compose v2 is required."
  exit 1
fi

if [[ ! -f .env ]]; then
  cp .env.example .env
  echo "Created .env from .env.example."
  echo "IMPORTANT: Edit .env and replace JUPYTER_TOKEN and MINIO_ROOT_PASSWORD."
  read -r -p "Press Enter after editing .env to continue, or Ctrl+C to stop."
fi

mkdir -p notebooks retail lakehouse/{raw,bronze,silver,gold,checkpoints}
touch notebooks/.gitkeep retail/.gitkeep \
  lakehouse/bronze/.gitkeep lakehouse/silver/.gitkeep lakehouse/gold/.gitkeep

docker compose config --quiet
echo "Setup checks passed. Start with ./scripts/up.sh"
