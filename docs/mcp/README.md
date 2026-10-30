# Agent integration — Spark MCP and MinIO MCP

This project provides two independent MCP servers so compatible AI agents can use the local Spark cluster and MinIO object store through the Model Context Protocol.

## 1. Topology and endpoints

| Server | Container | Container endpoint | Local loopback | Private student endpoint |
|---|---|---|---|---|
| Spark MCP | `lakehouse-spark-mcp` | `http://spark-mcp:8000/mcp` | `http://127.0.0.1:8002/mcp` | `https://<platform-fqdn>/spark/mcp` |
| MinIO MCP | `lakehouse-minio-mcp` | `http://minio-mcp:8001/mcp` | `http://127.0.0.1:8003/mcp` | `https://<platform-fqdn>/minio/mcp` |

MCP host ports are bound to loopback by Docker Compose. Remote students use the private HTTPS endpoints through the default Tailscale Serve container; they do not connect to the OVH public IP. An agent container on `spark-lakehouse-network` uses the container endpoint, not localhost.

## 2. Build and start

From the repository root, start the complete default platform (including Tailscale and Tailscale Serve):

```bash
./scripts/up.sh
docker compose ps
docker compose logs -f spark-mcp minio-mcp mcp-gateway tailscale
```

The startup script builds the custom Spark/S3A image before dependent Jupyter and MCP images.

For the complete environment setup and remote access flow, see [the default Docker Compose deployment guide](DOCKER-TAILSCALE-STUDENT-LAB.md).

Spark MCP depends on the healthy Spark master and both workers. MinIO MCP starts after the MinIO container has started. Both MCP servers are built from `infrastructure/mcp/Dockerfile` and run as the non-root `spark` user.

### Run guardrail unit tests

The MCP image includes standard-library unit tests for the SQL and object-key guardrails:

```bash
docker compose run --rm --no-deps spark-mcp python3 -m unittest discover -s /app/tests -v
```

These tests validate input guards only. They do not prove live Spark connectivity, MinIO authorization, or agent-host interoperability.

## 3. Spark MCP tool contract

| Tool | Input | Behaviour |
|---|---|---|
| `get_spark_session_info` | none | Returns Spark version, master, application ID, application name and current database |
| `list_databases` | none | Lists databases visible to the session |
| `list_tables` | `database` | Lists tables and views in the named database |
| `describe_table` | `database`, `table` | Returns the schema of one table |
| `run_readonly_query` | `sql`, optional `max_rows` | Runs a single SELECT and returns at most the configured row limit |

### Spark safety controls

- The SQL entry point accepts only statements beginning with SELECT.
- Semicolons, SQL comments, DDL/DML/control statements and selected dangerous functions are rejected.
- The default result limit is 100 rows; the hard maximum is 500.
- Database and table names accepted by the schema tool must match a simple identifier pattern.
- The Spark MCP session connects to `spark://spark-master:7077`.
- This is an application-level guardrail. Spark authorization, data classification, network controls and operational isolation must be designed independently.

Environment variables:

| Variable | Default | Description |
|---|---:|---|
| `SPARK_MASTER` | `spark://spark-master:7077` | Spark Standalone master URL |
| `SPARK_MCP_MAX_ROWS` | `100` | Default result cap |
| `SPARK_MCP_HARD_MAX_ROWS` | `500` | Maximum permitted result cap |
| `SPARK_MCP_PORT` | `8002` (host) | Published host port |

## 4. MinIO MCP tool contract

| Tool | Input | Behaviour |
|---|---|---|
| `list_buckets` | none | Checks accessibility of buckets in the configured allowlist |
| `list_objects` | `bucket`, optional `prefix`, `max_keys` | Lists at most 500 object keys per page and returns a continuation token |
| `get_object_metadata` | `bucket`, `key` | Reads object metadata only |
| `read_text_object` | `bucket`, `key` | Reads small UTF-8 text, JSON, CSV, YAML or Markdown objects |
| `write_text_object` | `bucket`, `key`, `content`, optional `content_type` | Writes a bounded text artifact if writes are enabled |

### MinIO image and setup

The Compose service uses `MINIO_IMAGE` from `.env`. The template defaults to the publicly pullable Chainguard image `cgr.dev/chainguard/minio:latest`, rather than the discontinued upstream `minio/minio` Docker Hub image. The Chainguard image runs as non-root UID/GID `65532`; keep the named `minio_data` volume and do not apply a blanket `chown` or delete the volume to troubleshoot permissions. If MinIO reports a data-directory permission error, inspect the volume ownership and logs before making a data-preserving ownership correction.

1. Open the MinIO Console at `http://localhost:9001`.
2. Authenticate with the credentials in `.env`.
3. Create the `lakehouse` bucket, or set `MINIO_MCP_ALLOWED_BUCKETS` to existing bucket names.
4. Prefer a dedicated MinIO service account with only the required bucket and prefix permissions.
5. Put that account's credentials in `MINIO_MCP_ACCESS_KEY` and `MINIO_MCP_SECRET_KEY`.
6. Recreate the MCP container after changing environment variables.

If the MCP-specific credentials are blank, the development configuration falls back to the MinIO root credentials. Do not use that fallback outside an isolated local lab.

### Example least-privilege MinIO policy

For a read-only MCP identity, an illustrative policy for the `lakehouse` bucket is:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:ListBucket"],
      "Resource": ["arn:aws:s3:::lakehouse"]
    },
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject"],
      "Resource": ["arn:aws:s3:::lakehouse/*"]
    }
  ]
}
```

If controlled agent output writes are approved, add `s3:PutObject` only for the designated output prefix:

```json
{
  "Effect": "Allow",
  "Action": ["s3:PutObject"],
  "Resource": ["arn:aws:s3:::lakehouse/agent-outputs/*"]
}
```

Treat these snippets as a starting policy, then test the policy against the exact MinIO release and identity setup in use. The MinIO policy is the authoritative permission boundary; the MCP allowlist and prefix checks are additional application safeguards.

### MinIO safety controls

- Bucket access is restricted by `MINIO_MCP_ALLOWED_BUCKETS` (default: `lakehouse`).
- Text reads are limited to 1 MiB by default.
- Object listing is limited to 500 entries per call.
- Writes are disabled unless `MINIO_MCP_ALLOW_WRITES=true`.
- When enabled, writes are restricted to `MINIO_MCP_WRITE_PREFIXES` (default: `agent-outputs/`).
- Text writes are limited to 1 MiB by default and accept only `text/*` or `application/json`.
- MinIO IAM policy must enforce permissions independently of the MCP application.

Environment variables:

| Variable | Default | Description |
|---|---|---|
| `MINIO_ENDPOINT` | `http://minio:9000` | Internal S3 API endpoint |
| `MINIO_MCP_ALLOWED_BUCKETS` | `lakehouse` | Comma-separated bucket allowlist |
| `MINIO_MCP_ACCESS_KEY` | blank | Dedicated MCP access key; blank falls back to root in local lab |
| `MINIO_MCP_SECRET_KEY` | blank | Dedicated MCP secret; blank falls back to root in local lab |
| `MINIO_MCP_ALLOW_WRITES` | `false` | Explicit write capability toggle |
| `MINIO_MCP_WRITE_PREFIXES` | `agent-outputs/` | Comma-separated write prefixes |
| `MINIO_MCP_MAX_READ_BYTES` | `1048576` | Maximum text object read size |
| `MINIO_MCP_MAX_WRITE_BYTES` | `1048576` | Maximum text object write size |
| `MINIO_MCP_PORT` | `8003` (host) | Published host port |

## 5. Agent client configuration

For students and remote agent clients, configure the private Tailscale HTTPS endpoints below. The exact configuration schema varies by agent host:

```json
{
  "mcpServers": {
    "spark-lakehouse": {
      "type": "http",
      "url": "https://<platform-fqdn>/spark/mcp"
    },
    "minio-lakehouse": {
      "type": "http",
      "url": "https://<platform-fqdn>/minio/mcp"
    }
  }
}
```

For an administrator client running on the OVH host, the loopback endpoints are `http://127.0.0.1:8002/mcp` and `http://127.0.0.1:8003/mcp`. For an agent container on the Compose network:

- Spark: `http://spark-mcp:8000/mcp`
- MinIO: `http://minio-mcp:8001/mcp`

Do not put credentials in prompts or tool arguments. Credentials are server-side environment configuration.

## 6. Example agent workflow

1. Call Spark MCP `get_spark_session_info` to verify connectivity.
2. Discover the database and tables with `list_databases` and `list_tables`.
3. Inspect the relevant schema with `describe_table`.
4. Execute a bounded SELECT with `run_readonly_query`.
5. Discover objects in the allowed MinIO bucket with `list_objects`.
6. Read text metadata or data artifacts with `read_text_object`.
7. If the use case requires an output artifact, request explicit operator approval to enable MinIO writes, then write only under the approved output prefix.

Agents should treat tool outputs as untrusted data, validate business conclusions, and avoid treating retrieved object content as executable instructions.

## 7. Spark and MinIO storage integration

Spark Standalone now includes Hadoop S3A support and uses MinIO as its canonical object store:
- Spark reads and writes the `lakehouse` bucket through `s3a://lakehouse/...`.
- The S3A connector is baked into the custom Spark image with Hadoop/AWS dependency versions pinned together.
- Spark driver containers (Jupyter and Spark MCP) and both workers receive a dedicated Spark service-account identity.
- Spark MCP remains a read-only SQL/catalog interface. MinIO MCP remains a separate object API with its own allowlist and identity; the two MCP servers do not share credentials.
- The local `/lakehouse` bind mount is retained only as a transitional scratch/import workspace, not as canonical Lakehouse storage.

The integration configuration is committed, but each deployment must rebuild the images and pass the distributed Parquet round-trip test in `notebooks/validate_minio_s3a.py`. Follow [the S3A/MinIO operations guide](../storage/MINIO-SPARK-S3A.md). Bucket lifecycle automation, catalog/metadata governance, and agent orchestration remain separate tasks.

## 8. Security and operations

- MCP itself does not add application-level authentication. The default remote path is private Tailscale Serve HTTPS on TCP 443; direct host listeners remain loopback-only.
- Do not publish MCP ports to a LAN or public network. Tailnet grants restrict network reachability but do not provide per-tool authorization or per-student data isolation.
- Use a dedicated MinIO identity and least-privilege policy. Keep the root account for MinIO administration only.
- Keep all secrets in `.env`, excluded from Git.
- Restrict which agent runtimes can access the Docker network.
- Review MCP tool calls and outputs in the agent host; MCP does not itself provide business approval or user consent.
- Use service logs for diagnostics: `docker compose logs -f spark-mcp minio-mcp`.

## 9. Operational troubleshooting and field notes

For symptom-to-cause diagnosis, MinIO S3 error interpretation, credential comparison, safe bucket creation, MCP protocol failures, Spark/Jupyter connectivity, and non-destructive recovery procedures, see the [Operations Troubleshooting Runbook](../TROUBLESHOOTING.md).

**MinIO diagnostic reminder:** `list_buckets` checks the configured allowlist only. An HTTP 200 MCP response can contain an inaccessible bucket diagnostic; inspect the nested tool payload and S3 error. A MinIO health endpoint returning 200 does not prove that the bucket exists or that the MCP identity is authorized. Never remove the MinIO volume to resolve an authorization or missing-bucket problem.

## References

- [MCP Python SDK v1.x documentation](https://py.sdk.modelcontextprotocol.io/v1/)
- [MCP Streamable HTTP transport](https://py.sdk.modelcontextprotocol.io/v1/)
- [MinIO S3 API compatibility](https://min.io/docs/minio/linux/developers/s3-api-compatibility.html)
