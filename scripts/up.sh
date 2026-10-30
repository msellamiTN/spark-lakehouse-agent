#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
[[ -f .env ]] || { echo "ERROR: .env is missing. Run ./scripts/setup.sh first."; exit 1; }
TS_AUTHKEY_VALUE="$(sed -n 's/^TS_AUTHKEY=//p' .env | tail -n 1)"
[[ -n "$TS_AUTHKEY_VALUE" && "$TS_AUTHKEY_VALUE" != *REPLACE* ]] || { echo "ERROR: Set a valid TS_AUTHKEY in .env."; exit 1; }
spark_image_value="$(sed -n 's/^SPARK_IMAGE=//p' .env | tail -n 1)"
[[ "$spark_image_value" == "spark-lakehouse-s3a:3.5.6" ]] || {
  echo "ERROR: Set SPARK_IMAGE=spark-lakehouse-s3a:3.5.6 in .env."
  exit 1
}
hadoop_version_value="$(sed -n 's/^HADOOP_VERSION=//p' .env | tail -n 1)"
aws_sdk_version_value="$(sed -n 's/^AWS_SDK_BUNDLE_VERSION=//p' .env | tail -n 1)"
[[ -z "$hadoop_version_value" || "$hadoop_version_value" == "3.3.4" ]] || { echo "ERROR: HADOOP_VERSION must remain 3.3.4 for this Spark base image."; exit 1; }
[[ -z "$aws_sdk_version_value" || "$aws_sdk_version_value" == "1.12.262" ]] || { echo "ERROR: AWS_SDK_BUNDLE_VERSION must remain 1.12.262 for hadoop-aws 3.3.4."; exit 1; }
for key in SPARK_S3A_ACCESS_KEY SPARK_S3A_SECRET_KEY; do
  value="$(sed -n "s/^${key}=//p" .env | tail -n 1)"
  [[ -n "$value" && "$value" != replace-* ]] || {
    echo "ERROR: Configure $key with the dedicated MinIO Spark service-account credential in .env."
    exit 1
  }
done
docker compose config --quiet
# Build the shared Spark/S3A base first; Jupyter and MCP images inherit it.
docker compose build spark-master
docker compose build jupyter spark-mcp minio-mcp
docker compose up -d
echo
echo "Complete platform started. Inspect Tailscale with:"
echo "  docker compose exec tailscale tailscale status"
echo "  docker compose exec tailscale tailscale serve status"
echo "Run ./scripts/validate.sh after services become healthy."
