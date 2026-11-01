#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."

echo "=== Lakehouse contract validation ==="
python3 scripts/validate_lakehouse_contracts.py

echo
echo "=== Lakehouse contract unit tests ==="
python3 -m unittest discover -s tests -v

echo
echo "Phase 2.1 local checks passed."
