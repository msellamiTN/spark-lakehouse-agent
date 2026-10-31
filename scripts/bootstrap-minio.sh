#!/usr/bin/env bash
# Provision persistent, bucket-scoped MinIO service accounts.
# Root credentials are used only by this one-shot bootstrap process.
set -Eeuo pipefail
cd "$(dirname "$0")/.."

fail() { echo "ERROR: $*" >&2; exit 1; }
[[ -f .env ]] || fail ".env is missing."
command -v docker >/dev/null 2>&1 || fail "Docker is required."
docker compose version >/dev/null 2>&1 || fail "Docker Compose v2 is required."

env_value() {
  local key="$1"
  sed -n "s/^\${key}=//p" .env | tail -n 1
}

root_user="$(env_value MINIO_ROOT_USER)"
root_password="$(env_value MINIO_ROOT_PASSWORD)"
[[ -n "$root_user" && -n "$root_password" ]] || fail "Set MINIO_ROOT_USER and MINIO_ROOT_PASSWORD in .env."

allowed_buckets="$(env_value MINIO_MCP_ALLOWED_BUCKETS)"
[[ -z "$allowed_buckets" || "$allowed_buckets" == "lakehouse" ]] || fail "This bootstrap currently provisions only the lakehouse bucket; set MINIO_MCP_ALLOWED_BUCKETS=lakehouse."

allow_writes="$(env_value MINIO_MCP_ALLOW_WRITES)"
write_prefixes="$(env_value MINIO_MCP_WRITE_PREFIXES)"
mcp_policy="minio-mcp-readonly.json"
if [[ "$allow_writes" == "true" ]]; then
  [[ -z "$write_prefixes" || "$write_prefixes" == "agent-outputs/" ]] || fail "IAM write permission is deliberately fixed to agent-outputs/; align MINIO_MCP_WRITE_PREFIXES."
  mcp_policy="minio-mcp-write.json"
fi

mkdir -p secrets
chmod 700 secrets
touch secrets/.gitkeep
mc_config="$(mktemp -d "$PWD/secrets/.mc-config.XXXXXX")"
chmod 700 "$mc_config"
trap 'rm -rf "$mc_config"' EXIT

mc_run() {
  docker compose run --rm -T --no-deps minio-init --config-dir "/secrets/$(basename "$mc_config")" "$@"
}

echo "Waiting for MinIO and configuring the bootstrap alias..."
mc_run alias set local http://minio:9000 "$root_user" "$root_password" --api S3v4 >/dev/null
ready=0
for attempt in $(seq 1 30); do
  if mc_run ready local >/dev/null 2>&1; then ready=1; break; fi
  sleep 2
done
[[ "$ready" == "1" ]] || fail "MinIO did not become ready within 60 seconds."

mc_run mb --ignore-existing local/lakehouse >/dev/null
echo "PASS: lakehouse bucket exists."

ensure_account() {
  local file="$1" access_key="$2" policy_file="$3" label="$4" access_var="$5" secret_var="$6"
  local existing_access output
  if [[ -s "$file" ]]; then
    existing_access="$(sed -n "s/^${access_var}=//p" "$file" | tail -n 1)"
    [[ "$existing_access" == "$access_key" ]] || fail "$label credentials file has an unexpected access key; review it manually."
    mc_run admin user svcacct info local "$access_key" >/dev/null || fail "$label service account is absent or disabled; use the documented rotation procedure."
    mc_run admin user svcacct edit --policy "/policies/$policy_file" local "$access_key" >/dev/null
    echo "PASS: existing $label service account retained; policy reconciled."
    return
  fi

  if mc_run admin user svcacct info local "$access_key" >/dev/null 2>&1; then
    fail "$label service account already exists but its secret file is missing. Refusing to rotate or overwrite credentials automatically; perform an explicit rotation."
  fi

  output="$(mc_run --json admin user svcacct add --access-key "$access_key" --policy "/policies/$policy_file" local "$root_user")" || fail "Could not create $label service account."
  mapfile -t credentials < <(
    printf '%s' "$output" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d.get("status") == "success"; print(d["accessKey"]); print(d["secretKey"])'
  )
  [[ "${#credentials[@]}" -eq 2 && -n "${credentials[0]}" && -n "${credentials[1]}" ]] || fail "MinIO did not return the expected $label credential response."
  local tmp="${file}.tmp"
  (umask 077; printf "%s=%s\n%s=%s\n" "$access_var" "${credentials[0]}" "$secret_var" "${credentials[1]}" > "$tmp")
  chmod 600 "$tmp"
  mv "$tmp" "$file"
  echo "PASS: created $label service account and stored its credentials."
}

ensure_account secrets/spark-s3a.env SPARKLAKEHOUSE01 spark-lakehouse.json Spark AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
ensure_account secrets/minio-mcp.env MINIOMCPLAKEHOUSE1 "$mcp_policy" MinIO-MCP MINIO_MCP_ACCESS_KEY MINIO_MCP_SECRET_KEY
chmod 600 secrets/spark-s3a.env secrets/minio-mcp.env

echo "MinIO bootstrap completed. Credentials were not displayed."
