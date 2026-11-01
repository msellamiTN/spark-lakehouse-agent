# Operations Runbook — Troubleshooting and Field Notes

For OVH Ubuntu operators and remote MCP client administrators.

> 🧭 **Golden rule:** diagnose from the outside inward: client → tailnet → Serve/gateway → MCP tool → backend → authorization → data. Change one layer at a time and preserve persistent volumes.

## 1. Fast diagnostic sequence

~~~bash
sudo docker compose config --quiet
sudo docker compose ps
sudo docker compose logs --tail=120 tailscale mcp-gateway spark-mcp minio-mcp
sudo docker compose exec tailscale tailscale status
sudo docker compose exec tailscale tailscale serve status
curl -i http://127.0.0.1:8088/healthz
curl -i http://127.0.0.1:9000/minio/health/live
curl -i http://127.0.0.1:9000/minio/health/ready
~~~

A green container health check proves only its configured check. It does not prove bucket existence, object permissions, MCP protocol compatibility, or successful Spark jobs.

## 2. Known incident: MinIO MCP reports inaccessible bucket

### Symptom

MinIO MCP list_buckets may return a diagnostic payload such as:

~~~json
{
  "configured_allowlist": ["lakehouse"],
  "buckets": [
    {"name": "lakehouse", "accessible": false, "error": "ClientError"}
  ]
}
~~~

The outer MCP response can have isError=false: the tool successfully returned a diagnostic payload, while the S3 request inside failed.

### Root-cause decision table

| Diagnostic result | Meaning | Correct next action |
|---|---|---|
| Root ListBuckets = 200, empty array | Root authentication works; no buckets exist | Create configured bucket |
| Root HeadBucket(lakehouse) = 404 | Bucket absent for authenticated root | Create lakehouse; do not reset volume |
| MCP identity = InvalidAccessKeyId | Access key unknown to this MinIO server | Correct MCP access key and loaded identity |
| MCP identity = 403 while root succeeds | MCP identity lacks permission or policy denies action | Inspect service-account policy and bucket actions |
| Root and MCP both have signature/auth errors | Credential mismatch, endpoint/region/signing issue, or stale environment | Verify endpoint and credentials without printing secrets |
| HeadBucket succeeds but ListBuckets fails | Bucket-level access exists; account-wide enumeration is not granted | Acceptable for least privilege; use bucket-scoped tools |
| MinIO health = 200 but S3 fails | HTTP process healthy; S3 auth, authorization or bucket state is not | Diagnose credentials, bucket and IAM separately |

### Verify service identity isolation

The current deployment does not pass MinIO root credentials into Spark, Jupyter, Spark MCP or MinIO MCP. Do not test the old root-credential fallback; it has been removed.

Run the supported end-to-end checks:

~~~bash
./scripts/up.sh
./scripts/validate.sh
~~~

The validation suite checks that Spark workers, Jupyter and Spark MCP have their S3A env vars but no `MINIO_ROOT_*` variables; MinIO MCP has its own `MINIO_MCP_*` identity and no root variables. It also tests bucket access and expected denial of account-wide bucket enumeration. With MCP writes disabled, it verifies that PutObject is denied.

Safe boolean-only spot checks:

~~~bash
docker compose exec spark-worker-1 sh -c 'test -n "$AWS_ACCESS_KEY_ID" && test -n "$AWS_SECRET_ACCESS_KEY" && test -z "${MINIO_ROOT_USER:-}" && echo "Spark identity present; no root identity"'
docker compose exec minio-mcp sh -c 'test -n "$MINIO_MCP_ACCESS_KEY" && test -n "$MINIO_MCP_SECRET_KEY" && test -z "${MINIO_ROOT_USER:-}" && echo "MCP identity present; no root identity"'
~~~

Never print the env files or environment values.

### Reconcile the bucket and service identities

Use the repository bootstrap instead of creating buckets or changing credentials through the MinIO MCP container:

~~~bash
bash ./scripts/bootstrap-minio.sh
~~~

The script waits for MinIO, creates `lakehouse` if absent, creates the Spark and MinIO MCP service accounts on first run, and reconciles their inline policies on later runs. It retains existing keys and does not rotate secrets automatically. If a service account exists but its local secret file is missing, stop and perform an explicit recovery/rotation; do not replace the file with root credentials.

Never run `docker compose down -v`, delete `minio_data`, or reset the MinIO root password to fix an authorization problem.
## 3. Common MinIO errors

### InvalidAccessKeyId
- Confirm the MCP container has the intended access key.
- If .env changed, recreate minio-mcp; containers do not reload environment automatically.
- Do not put `MINIO_MCP_ACCESS_KEY` or `MINIO_MCP_SECRET_KEY` in `.env`; the bootstrap manages both together in `secrets/minio-mcp.env`. There is no root fallback.
- Never print credentials in logs.

### 403 Forbidden
- Identify the failing operation: HeadBucket, ListBucket, GetObject, or PutObject.
- Check service-account policy, bucket policy, object prefix, and MCP bucket allowlist.
- Do not infer that a bucket is absent from a 403 alone.

### 404 for HeadBucket
- Run `bash ./scripts/bootstrap-minio.sh` to verify/create the configured bucket with the administrative bootstrap identity.
- If listed, verify exact spelling and endpoint.

### Empty list_objects result
An empty array is normal for a new bucket. It proves the list request completed, not that an object exists. Use a controlled write/read test only after write policy and MCP write configuration are explicitly enabled.

## 4. MCP endpoint and protocol troubleshooting

| Symptom | Likely layer | Checks |
|---|---|---|
| DNS name does not resolve | Tailscale / MagicDNS | Correct tailnet, MagicDNS, hostname from tailscale status |
| TLS certificate error | Tailscale HTTPS | HTTPS Certificates enabled; inspect Serve status |
| Connection timeout | Tailnet grants / routing | Client online; grant permits TCP 443; node online |
| HTTP 502 | Nginx → MCP upstream | MCP health/logs; upstream names and Docker network |
| HTTP 404 | Route path | Exact /spark/mcp or /minio/mcp path |
| HTTP 200 but JSON-RPC tool error | MCP application/backend | Inspect JSON-RPC error and tool payload |
| Unknown tool | Wrong endpoint or tool name | Spark tools on /spark/mcp; MinIO tools on /minio/mcp |
| initialize succeeds, tools/list fails | Protocol/client headers | Accept: application/json, text/event-stream; inspect logs |

PowerShell example:

~~~powershell
$uri = "https://<platform-fqdn>/minio/mcp"
$headers = @{
  "MCP-Protocol-Version" = "2025-03-26"
  "Accept" = "application/json, text/event-stream"
}
$body = @{
  jsonrpc = "2.0"
  id = 1
  method = "tools/call"
  params = @{ name = "list_buckets"; arguments = @{} }
} | ConvertTo-Json -Depth 10

Invoke-WebRequest -Uri $uri -Method POST -ContentType "application/json" -Headers $headers -Body $body
~~~

HTTP success alone does not prove the tool succeeded. Inspect JSON-RPC result, nested text payload, and isError.

## 5. Spark and Jupyter troubleshooting

### Spark MCP cannot reach Spark

~~~bash
sudo docker compose ps spark-master spark-worker-1 spark-worker-2 spark-mcp
sudo docker compose logs --tail=150 spark-master spark-worker-1 spark-worker-2 spark-mcp
sudo docker compose exec spark-mcp getent hosts spark-master
~~~

Confirm SPARK_MASTER=spark://spark-master:7077, master health, and worker registration. From a container, use Docker service DNS, not host localhost.

### Jupyter notebook cannot connect
- Check Jupyter health and token configuration.
- Verify SPARK_MASTER=spark://spark-master:7077 inside Jupyter.
- Confirm both workers are healthy and registered.
- Inspect Jupyter and Spark logs.

### Spark S3A ↔ MinIO integration

Rebuild the custom Spark runtime and dependent Jupyter/MCP images after updating the repository:

~~~bash
./scripts/up.sh
docker compose ps
./scripts/validate.sh
~~~

The startup script builds the Spark/S3A base before the Jupyter and MCP images that inherit it.

The S3A acceptance test is `notebooks/validate_minio_s3a.py`. It writes a temporary Parquet dataset under `lakehouse/_system/validation/`, reads it back through Spark executors, verifies the rows and removes only that unique test prefix.

| Symptom | Likely cause | Safe diagnostic |
|---|---|---|
| S3A FileSystem class not found | Custom Spark image not rebuilt or JAR missing | `docker compose exec jupyter ls /opt/spark/jars/hadoop-aws-3.3.4.jar` |
| Hadoop/AWS NoSuchMethodError | Dependency versions do not match | Check Hadoop 3.3.4, hadoop-aws 3.3.4 and AWS SDK bundle 1.12.262 |
| HTTP 403 / AccessDenied | Spark service account policy | Check bucket-scoped List/Get/Put/Delete permissions for the test prefix |
| InvalidAccessKeyId | Wrong or stale Spark service account key | Recreate Jupyter, Spark MCP and both workers after changing .env |
| Driver works, executors fail | AWS credentials missing from worker containers | Run the boolean-only credential-presence checks in the [S3A runbook](storage/MINIO-SPARK-S3A.md) |
| Could not resolve host minio | Driver not attached to Compose network or endpoint typo | Use `http://minio:9000` inside the Compose network |
| Signature mismatch | Path-style/endpoint configuration mismatch | Verify `fs.s3a.path.style.access=true` and the configured endpoint |

Do not print environment values while diagnosing credentials. Do not delete `minio_data`, run `docker compose down -v`, or reset MinIO to resolve an S3A error. See the [full S3A/MinIO runbook](storage/MINIO-SPARK-S3A.md).

## 6. Docker, host and persistence troubleshooting

### Docker socket permission denied

Use sudo docker compose or have an administrator configure Docker group membership. Membership in the docker group grants root-equivalent host control; treat it as privileged access.

### Container restarting or unhealthy

~~~bash
sudo docker compose ps
sudo docker compose logs --tail=200 <service>
sudo docker inspect --format '{{json .State.Health}}' <container-name>
~~~

Fix the underlying configuration or dependency first. Avoid repeated blind restarts.

### Disk pressure

~~~bash
df -h
sudo docker system df
sudo docker volume ls
~~~

Do not prune volumes or remove Docker data directories without confirming backup and ownership.

### Safe restart vs destructive reset

| Command | Effect | Guidance |
|---|---|---|
| docker compose restart SERVICE | Restart selected container | Non-destructive |
| docker compose up -d --force-recreate SERVICE | Recreate container with current config | Preserves named volumes |
| docker compose down | Remove project containers/network | Named volumes preserved |
| docker compose down -v | Also deletes named volumes | ⚠️ Destructive; avoid routinely |

## 7. Operational tips and field notes

- 🔎 **Observe before changing:** capture service state, relevant logs, and exact HTTP/JSON-RPC error first.
- 🔐 **Keep secrets out of evidence:** share error codes and booleans, never access keys, passwords, auth keys, or .env files.
- 🧱 **Separate health from readiness:** MinIO HTTP health can be green while a bucket is missing or an identity is unauthorized.
- 🪪 **Use least privilege:** root is for administration; MCP gets its own service identity and required bucket/prefix actions only.
- 🧪 **Test one operation at a time:** bucket head, object listing, metadata/read, then an approved write.
- 🧭 **Use the correct endpoint:** Spark and MinIO tools use different MCP paths.
- 💾 **Protect persistent state:** container recreation should not require deleting volumes.
- 📦 **Use the canonical lake:** MinIO is the Lakehouse object store; the local /lakehouse mount is transitional scratch/import space. S3A runtime acceptance is required after each rebuild.
- 🚦 **Do not equate HTTP 200 with workload success:** inspect JSON-RPC result and verify backend state.
- 📝 **Record the baseline:** image tags, Compose revision, validation date, and non-secret overrides.

## 8. Escalation evidence checklist

- [ ] docker compose ps output
- [ ] Relevant logs with tokens/credentials redacted
- [ ] Exact endpoint path and HTTP status
- [ ] JSON-RPC method/tool name and sanitized response
- [ ] S3 error code and operation (HeadBucket, ListBucket, GetObject, etc.)
- [ ] `./scripts/validate.sh` service-identity and IAM boundary results
- [ ] Current Git commit SHA and image tags
- [ ] Whether issue reproduces on loopback or only through Tailscale

Never attach .env, Tailscale auth keys, MinIO secrets, or unredacted authorization headers.


## 9. OVH deployment incident record — MinIO bucket access

**Observed failure sequence and confirmed recovery:**

| Check | Observed result | Interpretation |
|---|---|---|
| MinIO live/ready health | HTTP 200 | MinIO process and HTTP endpoint were reachable |
| Root ListBuckets | HTTP 200, empty bucket list | Root credentials authenticated; no buckets existed |
| Root HeadBucket(lakehouse) | HTTP 404 | Configured bucket was absent |
| MCP HeadBucket(lakehouse) | HTTP 403 | MCP identity did not have usable access |
| MCP ListBuckets | InvalidAccessKeyId | MCP access key was not recognized |
| MCP HeadBucket after credential correction and bucket provisioning | HTTP 200 | MCP credentials and bucket access now work |
| Remote MCP list_buckets | accessible=true, http_status=200 | Tailscale → Serve → Nginx → MinIO MCP → MinIO bucket check passed |

**What this incident teaches:**

- MinIO container health and S3 authorization are separate checks.
- Bucket absence and invalid MCP credentials were independent faults; fixing only one would not have completed recovery.
- The MinIO MCP list_buckets tool checks the configured allowlist and returns per-bucket diagnostics. It does not enumerate every bucket in the account.
- The successful HeadBucket and list_buckets checks validate bucket access, not object listing, object reads, writes, or Spark S3A integration.
- The credential alignment used for recovery is a temporary lab diagnostic measure. Replace it with a dedicated least-privilege MinIO service identity before treating the environment as a shared or production-like service.

**Current validation boundary:** bucket-level access was confirmed in the earlier MinIO MCP diagnostic. That check does not prove the newly configured Spark S3A integration. Rebuild the custom Spark image, provision the separate Spark service identity, then run the distributed Parquet round-trip validation.
