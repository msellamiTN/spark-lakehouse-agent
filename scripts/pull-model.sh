#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
MODEL="${1:-qwen2.5:3b}"

docker compose exec ollama ollama pull "$MODEL"
echo "Model downloaded: $MODEL"
echo "Set OLLAMA_MODEL=$MODEL in .env for later agent configuration."
