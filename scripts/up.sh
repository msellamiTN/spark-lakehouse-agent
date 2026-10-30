#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
[[ -f .env ]] || { echo "ERROR: .env is missing. Run ./scripts/setup.sh first."; exit 1; }
TS_AUTHKEY_VALUE="$(sed -n 's/^TS_AUTHKEY=//p' .env | tail -n 1)"
[[ -n "$TS_AUTHKEY_VALUE" && "$TS_AUTHKEY_VALUE" != *REPLACE* ]] || { echo "ERROR: Set a valid TS_AUTHKEY in .env."; exit 1; }
docker compose config --quiet
docker compose up -d --build
echo
echo "Complete platform started. Inspect Tailscale with:"
echo "  docker compose exec tailscale tailscale status"
echo "  docker compose exec tailscale tailscale serve status"
echo "Run ./scripts/validate.sh after services become healthy."
