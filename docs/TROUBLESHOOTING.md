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

### Safe identity comparison

Reports only whether MCP credentials equal root identity and tests both. It never prints secret values.

~~~bash
sudo docker compose exec -T minio-mcp python3 - <<'PY'
import os
import boto3
from botocore.config import Config
from botocore.exceptions import ClientError

endpoint = os.getenv("MINIO_ENDPOINT", "http://minio:9000")
root_user = os.getenv("MINIO_ROOT_USER", "")
root_password = os.getenv("MINIO_ROOT_PASSWORD", "")
mcp_user = os.getenv("MINIO_MCP_ACCESS_KEY", "")
mcp_password = os.getenv("MINIO_MCP_SECRET_KEY", "")

print("MCP access key equals root user:", mcp_user == root_user)
print("MCP secret equals root password:", mcp_password == root_password)

def test(label, user, password):
    print("\n---", label, "---")
    client = boto3.client(
        "s3", endpoint_url=endpoint,
        aws_access_key_id=user, aws_secret_access_key=password,
        region_name="us-east-1",
        config=Config(signature_version="s3v4",
                      retries={"max_attempts": 1},
                      s3={"addressing_style": "path"}),
    )
    for name, call in (
        ("HeadBucket lakehouse", lambda: client.head_bucket(Bucket="lakehouse")),
        ("ListBuckets", client.list_buckets),
    ):
        try:
            result = call()
            print(name, "SUCCESS",
                  result.get("ResponseMetadata", {}).get("HTTPStatusCode"))
            if name == "ListBuckets":
                print("Bucket names:", [b["Name"] for b in result.get("Buckets", [])])
        except ClientError as exc:
            error = exc.response.get("Error", {})
            print(name, "FAILED", "code:", error.get("Code"),
                  "status:", exc.response.get("ResponseMetadata", {}).get("HTTPStatusCode"))

if root_user and root_password:
    test("ROOT CONFIGURATION", root_user, root_password)
if mcp_user and mcp_password:
    test("MCP IDENTITY", mcp_user, mcp_password)
PY
~~~

### Create a missing bucket without deleting data

Only after root authentication succeeds. This creates the bucket; it does not remove or reinitialize MinIO storage.

~~~bash
sudo docker compose exec -T minio-mcp python3 - <<'PY'
import os
import boto3
from botocore.config import Config

client = boto3.client(
    "s3", endpoint_url=os.getenv("MINIO_ENDPOINT", "http://minio:9000"),
    aws_access_key_id=os.environ["MINIO_ROOT_USER"],
    aws_secret_access_key=os.environ["MINIO_ROOT_PASSWORD"],
    region_name="us-east-1",
    config=Config(signature_version="s3v4", s3={"addressing_style": "path"}),
)
try:
    client.create_bucket(Bucket="lakehouse")
    print("Created bucket: lakehouse")
except Exception as exc:
    print(type(exc).__name__, str(exc))
    raise
print("Buckets:", [b["Name"] for b in client.list_buckets().get("Buckets", [])])
PY
~~~

### Temporary lab recovery vs production configuration

For an isolated lab only, MCP credentials can temporarily be aligned with root credentials to prove the service path:

1. Set both MINIO_MCP_ACCESS_KEY and MINIO_MCP_SECRET_KEY in local .env to matching root values.
2. Recreate only the MCP container: docker compose up -d --force-recreate minio-mcp.
3. Validate S3 access from the MCP container, then call MCP list_buckets.
4. **Do not leave root credentials as the permanent MCP identity.**

For durable configuration, create a dedicated MinIO service account. Minimum read-only actions are typically s3:ListBucket on arn:aws:s3:::lakehouse and s3:GetObject on arn:aws:s3:::lakehouse/*. If writes are explicitly approved, add s3:PutObject only on arn:aws:s3:::lakehouse/agent-outputs/*. Verify against the deployed MinIO release and test the exact operations.

⚠️ Never run docker compose down -v, delete minio_data, reset the root password as a first response, or paste .env into chat to fix bucket authorization.

## 3. Common MinIO errors

### InvalidAccessKeyId
- Confirm the MCP container has the intended access key.
- If .env changed, recreate minio-mcp; containers do not reload environment automatically.
- Set both MCP variables together. The application falls back independently per variable, so setting only one can create a mismatched key pair.
- Never print credentials in logs.

### 403 Forbidden
- Identify the failing operation: HeadBucket, ListBucket, GetObject, or PutObject.
- Check service-account policy, bucket policy, object prefix, and MCP bucket allowlist.
- Do not infer that a bucket is absent from a 403 alone.

### 404 for HeadBucket
- Check the authenticated root identity's ListBuckets result.
- If absent, create the bucket with an administrative identity.
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
docker compose config --quiet
docker compose up -d --build
docker compose ps
./scripts/validate.sh
~~~

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
- [ ] Root vs MCP identity test results (booleans/results only)
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
