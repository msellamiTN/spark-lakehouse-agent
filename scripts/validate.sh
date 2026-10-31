#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

docker compose config --quiet || fail "Compose configuration is invalid"
pass "Compose configuration"

for svc in spark-master spark-worker-1 spark-worker-2 jupyter ollama minio spark-mcp minio-mcp mcp-gateway tailscale; do
  state="$(docker compose ps --status running --services | grep -Fx "$svc" || true)"
  [[ -n "$state" ]] || fail "$svc is not running"
  if [[ "$svc" == "minio" ]]; then
    pass "$svc is running"
    continue
  fi
  if [[ "$svc" == "tailscale" ]]; then
    pass "$svc container is running (tailnet validation follows)"
    continue
  fi
  health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}' "$(docker compose ps -q "$svc")")"
  [[ "$health" == "healthy" ]] || fail "$svc health is $health"
  pass "$svc is running and healthy"
done

docker compose exec -T spark-master bash -c "curl -fsS http://localhost:8080/ | grep -q 'Spark Master'" || fail "Spark master UI check"
pass "Spark master web UI"

docker compose exec -T mcp-gateway wget -q -O /dev/null http://127.0.0.1:8080/healthz || fail "MCP gateway health"
pass "MCP gateway health"

docker compose exec -T spark-mcp python3 -m unittest discover -s /app/tests -v || fail "MCP guardrail unit tests"
pass "MCP guardrail unit tests"

docker compose exec -T spark-mcp python3 -c "from spark_server import _spark; s=_spark(); print('Spark MCP connected:', s.version, s.sparkContext.master); s.stop()" || fail "Spark MCP to Spark cluster connectivity"
pass "Spark MCP to Spark cluster connectivity"

docker compose exec -T minio-mcp python3 -c "import urllib.request; r=urllib.request.urlopen('http://minio:9000/minio/health/live', timeout=5); print('MinIO MCP upstream:', r.status)" || fail "MinIO MCP to MinIO connectivity"
pass "MinIO MCP to MinIO connectivity"

# Confirm application containers receive only their dedicated service identities.
for svc in spark-worker-1 spark-worker-2 jupyter spark-mcp; do
  docker compose exec -T "$svc" sh -lc 'test -n "${AWS_ACCESS_KEY_ID:-}" && test -n "${AWS_SECRET_ACCESS_KEY:-}" && test -z "${MINIO_ROOT_USER:-}" && test -z "${MINIO_ROOT_PASSWORD:-}"' || fail "$svc is missing scoped S3A credentials or has root credentials"
done
pass "Spark workers, Jupyter and Spark MCP use non-root S3A credentials"

docker compose exec -T minio-mcp sh -lc 'test -n "${MINIO_MCP_ACCESS_KEY:-}" && test -n "${MINIO_MCP_SECRET_KEY:-}" && test -z "${MINIO_ROOT_USER:-}" && test -z "${MINIO_ROOT_PASSWORD:-}"' || fail "MinIO MCP is missing its dedicated identity or has root credentials"
pass "MinIO MCP has a dedicated identity and no root credentials"

# IAM negative tests: the two identities can access lakehouse but cannot enumerate all buckets.
docker compose exec -T jupyter python3 - <<'PY'
import boto3
from botocore.exceptions import ClientError

s3 = boto3.client("s3", endpoint_url="http://minio:9000", region_name="us-east-1")
s3.head_bucket(Bucket="lakehouse")
try:
    s3.list_buckets()
except ClientError as exc:
    code = exc.response.get("Error", {}).get("Code", "")
    if code not in {"AccessDenied", "AccessDeniedException", "403"}:
        raise
else:
    raise AssertionError("Spark service account unexpectedly has account-wide bucket enumeration.")
print("PASS: Spark identity can access lakehouse but cannot enumerate account buckets.")
PY
pass "Spark MinIO IAM boundary"

docker compose exec -T minio-mcp python3 - <<'PY'
import os
import boto3
from botocore.exceptions import ClientError

s3 = boto3.client(
    "s3",
    endpoint_url=os.getenv("MINIO_ENDPOINT", "http://minio:9000"),
    aws_access_key_id=os.environ["MINIO_MCP_ACCESS_KEY"],
    aws_secret_access_key=os.environ["MINIO_MCP_SECRET_KEY"],
    region_name="us-east-1",
)
s3.head_bucket(Bucket="lakehouse")
try:
    s3.list_buckets()
except ClientError as exc:
    code = exc.response.get("Error", {}).get("Code", "")
    if code not in {"AccessDenied", "AccessDeniedException", "403"}:
        raise
else:
    raise AssertionError("MinIO MCP identity unexpectedly has account-wide bucket enumeration.")

if os.getenv("MINIO_MCP_ALLOW_WRITES", "false").lower() != "true":
    try:
        s3.put_object(Bucket="lakehouse", Key="agent-outputs/_iam-validation-probe", Body=b"probe")
    except ClientError as exc:
        code = exc.response.get("Error", {}).get("Code", "")
        if code not in {"AccessDenied", "AccessDeniedException", "403"}:
            raise
    else:
        raise AssertionError("Read-only MinIO MCP identity unexpectedly wrote an object.")
print("PASS: MinIO MCP identity is bucket-scoped; read-only write denial verified when writes are disabled.")
PY
pass "MinIO MCP IAM boundary"

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
spark.stop()
PY
pass "Jupyter-to-Spark integration job"

docker compose exec -T jupyter python3 /workspace/notebooks/validate_minio_s3a.py || fail "Spark S3A to MinIO end-to-end validation"
pass "Spark S3A write/read Parquet integration"

docker compose exec -T ollama ollama list >/dev/null || fail "Ollama API/container check"
pass "Ollama API/container responds"

docker compose exec -T jupyter python3 - <<'PY'
import requests
r = requests.get("http://minio:9000/minio/health/live", timeout=5)
r.raise_for_status()
print("MinIO live endpoint:", r.status_code)
PY
pass "MinIO HTTP health endpoint"

docker compose exec -T tailscale tailscale status || fail "Tailscale node is not authenticated/connected"
docker compose exec -T tailscale tailscale serve status || fail "Tailscale Serve configuration unavailable"
pass "Tailscale node and Serve status"

echo
echo "All Phase 1 infrastructure checks passed."
echo "Remote endpoints (replace <tailnet> with the actual MagicDNS suffix):"
echo "  Spark MCP: https://spark-lakehouse-agent.<tailnet>.ts.net/spark/mcp"
echo "  MinIO MCP: https://spark-lakehouse-agent.<tailnet>.ts.net/minio/mcp"
