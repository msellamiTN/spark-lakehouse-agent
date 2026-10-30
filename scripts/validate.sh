#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

docker compose config --quiet || fail "Compose configuration is invalid"
pass "Compose configuration"

for svc in spark-master spark-worker-1 spark-worker-2 jupyter ollama minio spark-mcp minio-mcp; do
  state="$(docker compose ps --status running --services | grep -Fx "$svc" || true)"
  [[ -n "$state" ]] || fail "$svc is not running"
  if [[ "$svc" == "minio" ]]; then
    pass "$svc is running"
    continue
  fi
  health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}' \
    "$(docker compose ps -q "$svc")")"
  [[ "$health" == "healthy" ]] || fail "$svc health is $health"
  pass "$svc is running and healthy"
done

docker compose exec -T spark-master bash -lc \
  "curl -fsS http://localhost:8080/ | grep -q 'Spark Master'" \
  || fail "Spark master UI check"
pass "Spark master web UI"

docker compose exec -T jupyter python3 - <<'PY'
from pyspark.sql import SparkSession
spark = (SparkSession.builder
         .appName("phase1-validation")
         .master("spark://spark-master:7077")
         .config("spark.executor.instances", "2")
         .getOrCreate())
rows = spark.range(0, 1000).count()
assert rows == 1000, rows
print(f"Spark distributed count: {rows}")
print("Spark version:", spark.version)
print("Master:", spark.sparkContext.master)
print("Executors:", spark.sparkContext._jsc.sc().getExecutorMemoryStatus().size())
spark.stop()
PY
pass "Jupyter-to-Spark integration job"

docker compose exec -T ollama ollama list >/dev/null
pass "Ollama API/container responds (model availability checked separately)"

docker compose exec -T jupyter python3 - <<'PY'
import requests
r = requests.get("http://minio:9000/minio/health/live", timeout=5)
r.raise_for_status()
print("MinIO live endpoint:", r.status_code)
PY
pass "MinIO HTTP health endpoint"

echo
echo "All Phase 1 infrastructure and MCP service checks passed."
echo "Open:"
echo "  Spark Master:  http://localhost:8080"
echo "  Worker 1:      http://localhost:8081"
echo "  Worker 2:      http://localhost:8082"
echo "  JupyterLab:    http://localhost:8888"
echo "  Ollama API:    http://localhost:11434"
echo "  MinIO Console: http://localhost:9001"
echo "  Spark MCP:     http://localhost:8002/mcp"
echo "  MinIO MCP:     http://localhost:8003/mcp"
