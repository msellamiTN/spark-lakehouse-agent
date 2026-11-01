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
  docker compose exec -T "$svc" sh -c 'test -n "${AWS_ACCESS_KEY_ID:-}" && test -n "${AWS_SECRET_ACCESS_KEY:-}" && test -z "${MINIO_ROOT_USER:-}" && test -z "${MINIO_ROOT_PASSWORD:-}"' || fail "$svc is missing scoped S3A credentials or has root credentials"
done
pass "Spark workers, Jupyter and Spark MCP use non-root S3A credentials"

docker compose exec -T minio-mcp sh -c 'test -n "${MINIO_MCP_ACCESS_KEY:-}" && test -n "${MINIO_MCP_SECRET_KEY:-}" && test -z "${MINIO_ROOT_USER:-}" && test -z "${MINIO_ROOT_PASSWORD:-}"' || fail "MinIO MCP is missing its dedicated identity or has root credentials"
pass "MinIO MCP has a dedicated identity and no root credentials"

# IAM isolation tests.
# MinIO filters ListBuckets results by permissions in this deployment, so a
# successful list_buckets() call is not evidence of account-wide access.
# Create a temporary unrelated bucket with the root identity, then verify
# that neither application identity can address it directly.
env_value() {
  sed -n "s/^$1=//p" .env | tail -n 1
}

root_user="$(env_value MINIO_ROOT_USER)"
root_password="$(env_value MINIO_ROOT_PASSWORD)"
[[ -n "$root_user" && -n "$root_password" ]] || fail "MinIO root credentials are missing from .env."

iam_probe_bucket="iam-boundary-probe-$(date +%s)-$$"
iam_probe_config="$(mktemp -d "$PWD/secrets/.mc-iam-probe.XXXXXX")"
chmod 700 "$iam_probe_config"
iam_probe_created=0
iam_probe_object_key="agent-outputs/_iam-validation-probe-$(date +%s%N)"

mc_probe() {
  docker compose run --rm -T --no-deps minio-init \
    --config-dir "/secrets/$(basename "$iam_probe_config")" "$@"
}

cleanup_iam_probe() {
  if [[ "$(env_value MINIO_MCP_ALLOW_WRITES)" == "true" ]]; then
    mc_probe rm --force "local/lakehouse/$iam_probe_object_key" >/dev/null 2>&1 || true
  fi
  if [[ "$iam_probe_created" == "1" ]]; then
    mc_probe rb --force "local/$iam_probe_bucket" >/dev/null 2>&1 \
      || echo "WARNING: could not remove temporary IAM probe bucket $iam_probe_bucket." >&2
  fi
  if [[ -n "${iam_probe_config:-}" && -d "$iam_probe_config" ]]; then
    rm -rf -- "$iam_probe_config"
  fi
  unset root_user root_password
}
trap cleanup_iam_probe EXIT

mc_probe alias set local http://minio:9000 "$root_user" "$root_password" --api S3v4 >/dev/null \
  || fail "Could not configure the temporary containerized MinIO Client."
mc_probe mb "local/$iam_probe_bucket" >/dev/null \
  || fail "Could not create the unrelated IAM probe bucket."
iam_probe_created=1
pass "Temporary unrelated IAM probe bucket created"

docker compose exec -T jupyter python3 - "$iam_probe_bucket" <<'PY'
import sys
import boto3
from botocore.config import Config
from botocore.exceptions import ClientError

s3 = boto3.client(
    "s3",
    endpoint_url="http://minio:9000",
    region_name="us-east-1",
    config=Config(signature_version="s3v4", s3={"addressing_style": "path"}),
)
s3.head_bucket(Bucket="lakehouse")
try:
    s3.head_bucket(Bucket=sys.argv[1])
except ClientError as exc:
    code = exc.response.get("Error", {}).get("Code", "")
    if code not in {"AccessDenied", "AccessDeniedException", "403"}:
        raise
    print("PASS: Spark can access lakehouse but cannot directly access the unrelated bucket.")
else:
    raise SystemExit("FAIL: Spark can directly access the unrelated bucket.")
PY
pass "Spark MinIO bucket isolation"

docker compose exec -T minio-mcp python3 - "$iam_probe_bucket" "$iam_probe_object_key" <<'PY'
import os
import sys
import boto3
from botocore.config import Config
from botocore.exceptions import ClientError

s3 = boto3.client(
    "s3",
    endpoint_url=os.getenv("MINIO_ENDPOINT", "http://minio:9000"),
    aws_access_key_id=os.environ["MINIO_MCP_ACCESS_KEY"],
    aws_secret_access_key=os.environ["MINIO_MCP_SECRET_KEY"],
    region_name="us-east-1",
    config=Config(signature_version="s3v4", s3={"addressing_style": "path"}),
)
s3.head_bucket(Bucket="lakehouse")
try:
    s3.head_bucket(Bucket=sys.argv[1])
except ClientError as exc:
    code = exc.response.get("Error", {}).get("Code", "")
    if code not in {"AccessDenied", "AccessDeniedException", "403"}:
        raise
    print("PASS: MinIO MCP can access lakehouse but cannot directly access the unrelated bucket.")
else:
    raise SystemExit("FAIL: MinIO MCP can directly access the unrelated bucket.")

probe_key = sys.argv[2]
outside_key = "_iam-validation-probe-" + str(os.getpid())
allow_writes = os.getenv("MINIO_MCP_ALLOW_WRITES", "false").lower() == "true"
if allow_writes:
    s3.put_object(Bucket="lakehouse", Key=probe_key, Body=b"temporary IAM validation probe")
    try:
        s3.put_object(Bucket="lakehouse", Key=outside_key, Body=b"must be denied")
    except ClientError as exc:
        code = exc.response.get("Error", {}).get("Code", "")
        if code not in {"AccessDenied", "AccessDeniedException", "403"}:
            raise
        print("PASS: MinIO MCP writes are confined to agent-outputs/.")
    else:
        raise SystemExit("FAIL: MinIO MCP wrote outside agent-outputs/.")
else:
    try:
        s3.put_object(Bucket="lakehouse", Key=probe_key, Body=b"must be denied")
    except ClientError as exc:
        code = exc.response.get("Error", {}).get("Code", "")
        if code not in {"AccessDenied", "AccessDeniedException", "403"}:
            raise
        print("PASS: read-only MinIO MCP write was denied.")
    else:
        raise SystemExit("FAIL: read-only MinIO MCP identity unexpectedly wrote an object.")
PY
pass "MinIO MCP bucket isolation and write boundary"

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
