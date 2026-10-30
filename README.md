# Spark Lakehouse Agent Platform

A containerized Spark Lakehouse and MCP platform for Data Engineering and Agentic AI training. The **default deployment is one Docker Compose stack**, including Spark, JupyterLab, Ollama, MinIO, both MCP servers, an Nginx MCP gateway, and a Tailscale container with declarative Tailscale Serve.

**No host installation of Spark, Java, Python, Jupyter, MinIO, Nginx, or Tailscale is required.** The OVH server needs Docker Engine and Docker Compose v2. Students can connect from Windows, macOS, or Linux using their own Tailscale client; Google Colab uses the supplied notebook workflow.

## 1. Platform services

| Service | Version / role | Access |
|---|---|---|
| Spark Standalone | Spark 3.5.6, one master + two workers | Internal Docker network; UI loopback |
| JupyterLab | Custom image, PySpark enabled | Loopback |
| Ollama | 0.12.6, default model Qwen 2.5 3B | Loopback API |
| MinIO | Persistent S3-compatible object storage | Loopback API and console |
| Spark MCP | Streamable HTTP, bounded read-only Spark tools | Local loopback + private Serve |
| MinIO MCP | Streamable HTTP, bucket-scoped object tools | Local loopback + private Serve |
| MCP Gateway | Nginx path router, SSE/streaming aware | Internal; loopback diagnostics |
| Tailscale | Containerized userspace networking | Private tailnet |
| Tailscale Serve | HTTPS 443, configured from JSON | Tailnet only; Funnel disabled |

MinIO is the canonical object-storage layer for the Lakehouse (Raw → Bronze → Silver → Gold). The Compose configuration now builds a Spark image with the Hadoop S3A connector and configures Spark drivers/workers to access the MinIO `lakehouse` bucket. After creating the dedicated Spark MinIO service account, rebuild the images and run `./scripts/validate.sh` to verify distributed Parquet write/read. The local `./lakehouse` mount is retained only for transitional scratch/import workflows. Retail ingestion, CrewAI orchestration, and Streamlit dashboards remain later phases.

## 2. Architecture

The following high-resolution SVG is the **canonical deployment architecture** for Phase 1. It documents the private access path, Tailscale sidecar/network namespace, Nginx MCP routing, compute and storage services, the Spark S3A-to-MinIO path, and persistence domains.

![Spark Lakehouse Agent Platform — Phase 1 professional architecture](docs/diagrams/phase-1-architecture.svg)

[Open the deployment SVG](docs/diagrams/phase-1-architecture.svg) · [Open the logical MinIO + Spark Lakehouse SVG](docs/diagrams/logical-lakehouse-minio-spark.svg) · [Read the detailed architecture document](docs/ARCHITECTURE.md)

**Remote endpoints** (replace the tailnet suffix with the actual name shown by `tailscale status`):

- Spark MCP: `https://spark-lakehouse-agent.<tailnet>.ts.net/spark/mcp`
- MinIO MCP: `https://spark-lakehouse-agent.<tailnet>.ts.net/minio/mcp`

Tailscale Serve routes both paths over HTTPS 443. The MCP services are not exposed on the OVH public interface.

### Logical data architecture — MinIO is the data lake

![Logical Lakehouse data architecture: MinIO Raw, Bronze, Silver, Gold zones processed by Spark](docs/diagrams/logical-lakehouse-minio-spark.svg)

All four Medallion zones are logical prefixes in the persistent MinIO `lakehouse` bucket. Spark is the transformation engine and accesses those prefixes through `s3a://lakehouse/...`. The Compose configuration includes the S3A connector and MinIO endpoint; rebuild the custom images and pass the distributed Parquet round-trip test before considering the integration operational on a given host.

## 3. Prerequisites

### Server (OVH Ubuntu)
- Docker Engine
- Docker Compose v2 plugin
- Outbound Internet access for image pulls and Tailscale control-plane connectivity
- Recommended: 16 GB RAM minimum, 32 GB preferred; 4+ CPU cores; 30+ GB free disk

The server does **not** need host-level Tailscale, Nginx, Java, Spark, Python, or MinIO installations.

### Students
- Windows, macOS, or Linux
- Official Tailscale client, signed in to an account authorized by the tailnet administrator
- An MCP-compatible client/IDE/agent

For Google Colab, use `notebooks/01_colab_private_mcp_validation.ipynb`; it creates a temporary userspace Tailscale node and SOCKS5 proxy.

## 4. One-time Tailscale administration

Before first deployment, the tailnet administrator must:
1. Enable MagicDNS.
2. Enable HTTPS Certificates.
3. Define and authorize `tag:spark-lakehouse-mcp`.
4. Generate a reusable, non-ephemeral auth key restricted to that tag for the long-running platform container.
5. Add a grant/ACL allowing the student group to reach only this platform node on TCP 443.

Students use their own identities. Never share the platform auth key with students. Tailscale Serve is tailnet-only and Funnel is disabled in the checked-in Serve configuration.

## 5. Configure and deploy (step by step)

This runbook assumes the platform is deployed on your OVH Ubuntu server. It is safe to use when updating an existing checkout: **keep your current `.env` and Docker volumes**.

### Step 1 — Connect to the OVH server

From your administrator workstation:

```bash
ssh <your-ovh-user>@<your-server-ip>
```

Then go to the repository directory. If you already cloned it, use that checkout:

```bash
cd ~/spark-lakehouse-agent
```

If this is a new server and the repository is not present yet:

```bash
git clone https://github.com/msellamiTN/spark-lakehouse-agent.git
cd spark-lakehouse-agent
```

### Step 2 — Update the repository without overwriting secrets

For an existing deployment, first check whether you have local changes, then pull the latest committed version:

```bash
git status --short
git pull --ff-only
```

If `git pull` refuses because you have local changes, stop and review them before proceeding; do not use `git reset --hard`.

Confirm Docker and the Compose plugin are available:

```bash
docker --version
docker compose version
```

### Step 3 — Create or update `.env`

If `.env` does not exist yet:

```bash
cp .env.example .env
chmod 600 .env
```

If `.env` already exists, **do not copy `.env.example` over it**. Preserve your existing Jupyter token, MinIO credentials, ports, and other settings.

Open the file with your preferred editor:

```bash
nano .env
```

Ensure these variables exist and contain real values:

```dotenv
JUPYTER_TOKEN=<a-long-random-secret>
MINIO_ROOT_USER=<your-minio-admin-user>
MINIO_ROOT_PASSWORD=<a-long-random-password>
SPARK_S3A_ACCESS_KEY=<dedicated-spark-minio-service-account-key>
SPARK_S3A_SECRET_KEY=<dedicated-spark-minio-service-account-secret>
SPARK_BASE_IMAGE=apache/spark:3.5.6-scala2.12-java17-python3-ubuntu
SPARK_IMAGE=spark-lakehouse-s3a:3.5.6
TS_AUTHKEY=tskey-auth-<your-tagged-reusable-key>
TS_HOSTNAME=spark-lakehouse-agent
```

Create a dedicated MinIO Spark service account and attach the bucket-scoped policy in [the S3A/MinIO runbook](docs/storage/MINIO-SPARK-S3A.md). Existing deployments must update `SPARK_IMAGE` to `spark-lakehouse-s3a:3.5.6` and add the new `SPARK_BASE_IMAGE` and `SPARK_S3A_*` variables; the existing `.env` is intentionally not overwritten. Keep its access key and secret in the two `SPARK_S3A_*` variables; do not reuse MinIO root credentials. Use the actual variable names and any additional required settings already present in your `.env.example`. Do not paste secrets into chat, commit `.env`, or give the platform Tailscale auth key to students. The Tailscale key must be a reusable, non-ephemeral key restricted to `tag:spark-lakehouse-mcp`. If you need to replace a key, create the replacement in the Tailscale admin console and update only the `TS_AUTHKEY` value.

Check that the key is not still the sample placeholder without printing the secret:

```bash
if ! grep -q '^TS_AUTHKEY=tskey-auth-' .env || grep -q 'REPLACE' .env; then
  echo "ERROR: Set a real tagged TS_AUTHKEY in .env"
  exit 1
fi
```

### Step 4 — Check Tailscale admin prerequisites

Before starting the container, confirm in the Tailscale admin console:

1. MagicDNS is enabled.
2. HTTPS Certificates are enabled.
3. The tag `tag:spark-lakehouse-mcp` is defined and the auth key is permitted to use it.
4. A grant/ACL permits the intended student identities or group to reach this platform node on TCP 443.
5. Students will authenticate with their own Tailscale accounts; they do not use the server's auth key.

### Step 5 — Validate the Compose configuration

Run this from the repository root:

```bash
docker compose config --quiet
```

If it reports a missing variable or invalid configuration, fix `.env` before continuing. Do not start the stack until this command succeeds.

### Step 6 — Build the S3A runtime and start the complete platform

Use the supplied script so the shared Spark/S3A base image is built before Jupyter and MCP images that inherit it:

```bash
./scripts/up.sh
docker compose ps
```

On Windows PowerShell, run `.\\scripts\\up.ps1`.

The default Compose file starts Spark, JupyterLab, Ollama, MinIO, both MCP servers, the Nginx gateway, and the Tailscale sidecar. **Do not add an overlay Compose file and do not run a host-level `tailscale serve` command.**

### Step 7 — Check the Tailscale node and HTTPS routes

```bash
docker compose logs --tail=100 tailscale mcp-gateway
docker compose exec tailscale tailscale status
docker compose exec tailscale tailscale serve status
curl -fsS http://127.0.0.1:8088/healthz
```

The Tailscale node should appear online, and Serve should show HTTPS on port 443 proxying to the local Nginx gateway. The gateway health check should return successfully.

Read the exact MagicDNS hostname shown by the Tailscale status output. The expected name is normally:

```text
spark-lakehouse-agent.<your-tailnet>.ts.net
```

Do not guess the tailnet suffix; use the hostname actually assigned by Tailscale.

### Step 8 — Run the platform validation

```bash
./scripts/validate.sh
```

Review any failed check before giving students access. Also inspect service logs when needed:

```bash
docker compose logs --tail=100 spark-master spark-worker-1 spark-worker-2
docker compose logs --tail=100 spark-mcp minio-mcp
```

### Step 9 — Test from a student device

On a Windows, macOS, or Linux student device:

1. Install the official Tailscale client.
2. Sign in using the student's own account.
3. Confirm the device is connected to the authorized tailnet.
4. Configure the MCP client with the exact host name confirmed in Step 7 and the paths in [Student connection](#6-student-connection).
5. Test MCP `initialize` and `tools/list` from the MCP client. A browser GET by itself is not a valid end-to-end MCP test.

For Google Colab, use `notebooks/01_colab_private_mcp_validation.ipynb`. Set the exact platform hostname in the notebook and store a separate **ephemeral** Tailscale auth key in Colab Secrets as `TS_AUTHKEY`. Never reuse the long-lived platform key in Colab.

### Step 10 — Retire the old host-level Serve routes only after testing

If this OVH server previously used host-installed Tailscale, keep that host service running until the new Dockerized Tailscale node and both student MCP routes have been tested successfully.

Inspect the old host configuration:

```bash
sudo tailscale status
sudo tailscale serve status
```

Only if the old host Serve configuration contains **only the obsolete MCP routes** and the new Dockerized routes work from a student device, remove the old Serve configuration:

```bash
sudo tailscale serve reset
```

This resets Serve configuration on the **host Tailscale node**, not the Dockerized node. Do not uninstall or stop host `tailscaled` if you still use it for SSH/admin access or other services. Do not run `tailscale down` as part of this migration.

### Convenience scripts

Once `.env` is correctly configured, the repository also provides:

Linux / macOS:
```bash
./scripts/setup.sh
./scripts/up.sh
./scripts/validate.sh
```

Windows PowerShell:
```powershell
.\\scripts\\setup.ps1
.\\scripts\\up.ps1
.\\scripts\\validate.ps1
```

The manual steps above are recommended for the first migration because they make each safety check explicit.

## 6. Student connection

1. Install Tailscale on the student device and sign in with an authorized individual account.
2. Confirm the device is connected to the same tailnet and MagicDNS is enabled.
3. Configure the MCP client with:

```text
Spark MCP: https://spark-lakehouse-agent.<tailnet>.ts.net/spark/mcp
MinIO MCP: https://spark-lakehouse-agent.<tailnet>.ts.net/minio/mcp
```

Replace `<tailnet>` with the actual DNS suffix. The exact hostname can be read from `docker compose exec tailscale tailscale status`.

For MCP Streamable HTTP POST, clients must send:
```http
Content-Type: application/json
Accept: application/json, text/event-stream
```

A browser GET is not a complete MCP protocol test. Validate with MCP initialize and tools/list.

## 7. Local administrator endpoints

The following ports are bound to host loopback only:

| Service | URL |
|---|---|
| Spark Master UI | `http://127.0.0.1:8080` |
| Worker 1 UI | `http://127.0.0.1:8081` |
| Worker 2 UI | `http://127.0.0.1:8082` |
| JupyterLab | `http://127.0.0.1:8888` |
| Ollama API | `http://127.0.0.1:11434` |
| MinIO Console | `http://127.0.0.1:9001` |
| Spark MCP (local only) | `http://127.0.0.1:8002/mcp` |
| MinIO MCP (local only) | `http://127.0.0.1:8003/mcp` |
| MCP Gateway diagnostics | `http://127.0.0.1:8088/healthz` |

Change host ports in `.env` if they conflict. Do not change loopback bindings to `0.0.0.0`.

## 8. Lakehouse object layout

The canonical data path is the MinIO bucket `lakehouse`, accessed by Spark using Hadoop S3A:

```text
s3a://lakehouse/
├── raw/<source>/<dataset>/
├── bronze/<domain>/<dataset>/
├── silver/<domain>/<dataset>/
├── gold/<product>/<dataset>/
├── checkpoints/<pipeline>/
├── quarantine/<domain>/
└── _system/validation/
```

Parquet is the baseline data format. The local `./lakehouse:/lakehouse` mount remains temporarily for legacy scratch/import workflows; it is not the canonical data lake. MinIO persists all lake objects in the named `minio_data` volume. See [the Spark S3A ↔ MinIO runbook](docs/storage/MINIO-SPARK-S3A.md) for service-account policy, configuration, rebuild and validation.

## 9. Operations

```bash
docker compose ps
docker compose logs -f tailscale mcp-gateway spark-mcp minio-mcp
docker compose logs -f spark-master spark-worker-1 spark-worker-2
docker compose down
docker compose up -d
```

`docker compose down` preserves named volumes. `docker compose down -v` deletes persisted MinIO data, model cache, Jupyter configuration, and Tailscale identity. Use the latter only for an intentional destructive reset.

## 10. Security and multi-student boundary

- No MCP listener is published on the public OVH interface.
- Only Tailscale Serve TCP 443 is reachable to authorized tailnet members.
- Funnel is disabled.
- Do not expose Jupyter, Spark UI/RPC, MinIO API/console, Ollama, or Docker daemon to students.
- Keep Spark MCP bounded and read-only; MinIO writes are disabled by default.
- Spark uses a dedicated MinIO service account for S3A; do not reuse MinIO root credentials. The current shared Spark identity is not per-student isolation.
- Tailscale ACLs control network reachability; they do not isolate individual student data, Spark sessions, MinIO buckets, or MCP tool permissions. Before sharing sensitive data or enabling writes, implement per-team buckets/service accounts and Spark-side authorization/session isolation.
- This is a training/lab deployment, not a production-hardened multi-tenant platform.

## 11. Documentation

- [Default Docker Compose + Tailscale Serve deployment](docs/mcp/DOCKER-TAILSCALE-STUDENT-LAB.md)
- [Remote access from Windows and Google Colab](docs/mcp/COLAB-ACCESS.md)
- [MCP tool contracts and safety controls](docs/mcp/README.md)
- [Phase 1 technical notes](docs/PHASE-1.md)
- [Platform architecture — deployment, data flow, security boundaries and decisions](docs/ARCHITECTURE.md)
- [Operations troubleshooting and field notes](docs/TROUBLESHOOTING.md)
- [Architecture diagrams](docs/diagrams/README.md)
- [Spark S3A ↔ MinIO integration runbook](docs/storage/MINIO-SPARK-S3A.md)

---

**Data2AI — Spark Lakehouse Agent Platform**  
Deploy once with Docker Compose; connect students privately through Tailscale.
