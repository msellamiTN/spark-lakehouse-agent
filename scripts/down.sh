#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
docker compose down
echo "Containers stopped. Named volumes and data are preserved."
echo "To remove volumes as well, use: docker compose down -v"
