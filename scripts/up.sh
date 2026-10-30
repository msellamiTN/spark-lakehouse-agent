#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."

if [[ ! -f .env ]]; then
  echo "ERROR: .env is missing. Run ./scripts/setup.sh first."
  exit 1
fi

docker compose config --quiet
docker compose up -d --build
echo
echo "Services started. Run ./scripts/validate.sh to verify the deployment."
