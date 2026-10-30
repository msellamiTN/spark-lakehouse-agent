# Phase 1 — Infrastructure Foundation

## Services

| Service | Container | Host endpoint |
|---|---|---|
| Spark master UI | lakehouse-spark-master | http://localhost:8080 |
| Spark master RPC | lakehouse-spark-master | localhost:7077 |
| Spark worker 1 UI | lakehouse-spark-worker-1 | http://localhost:8081 |
| Spark worker 2 UI | lakehouse-spark-worker-2 | http://localhost:8082 |
| JupyterLab | lakehouse-jupyter | http://localhost:8888 |
| Ollama | lakehouse-ollama | http://localhost:11434 |
| MinIO API | lakehouse-minio | http://localhost:9000 |
| MinIO Console | lakehouse-minio | http://localhost:9001 |
| Spark MCP | lakehouse-spark-mcp | http://localhost:8002/mcp |
| MinIO MCP | lakehouse-minio-mcp | http://localhost:8003/mcp |
| Tailscale Serve | lakehouse-tailscale | https://<platform-fqdn>/spark/mcp and /minio/mcp |

## Requirements

- Docker Desktop with Docker Compose v2, or Docker Engine + Compose plugin.
- Outbound HTTPS access to Docker registries, Maven Central (`repo.maven.apache.org`) for the pinned S3A JARs, and the Tailscale control plane.
- For the default remote deployment, a tagged Tailscale auth key and tailnet admin setup (MagicDNS, HTTPS certificates, grants).
- 16 GB RAM minimum recommended for a light local run; 32 GB preferred.
- At least 20 GB free disk space if pulling the Qwen model.
- Virtualization enabled when using Docker Desktop on Windows.

The default worker allocation is 2 cores and 3 GiB per worker. Tune `.env` to fit the host. Leave memory for Docker, Ollama and the operating system. Tailscale and Tailscale Serve run in the default Compose stack using userspace networking; no host `tailscaled`, `/dev/net/tun`, or manual `tailscale serve` command is required.

## Linux / macOS

```bash
cp .env.example .env
# Edit .env; replace the sample credentials and token.
chmod +x scripts/*.sh
./scripts/setup.sh
./scripts/up.sh
./scripts/validate.sh
./scripts/pull-model.sh
```

## Windows PowerShell

```powershell
Copy-Item .env.example .env
# Edit .env; replace the sample credentials and token.
.\scripts\setup.ps1
.\scripts\up.ps1
.\scripts\validate.ps1
docker compose exec ollama ollama pull qwen2.5:3b
```

## Remote student access

The default Compose deployment includes a Tailscale container and declarative Tailscale Serve configuration. Students connect from Windows, macOS, or Linux using their own Tailscale client. Remote endpoints are `https://<platform-fqdn>/spark/mcp` and `https://<platform-fqdn>/minio/mcp`. See [the default deployment guide](mcp/DOCKER-TAILSCALE-STUDENT-LAB.md).

## MCP agent interfaces

Phase 1 includes two Streamable HTTP MCP servers for compatible agents:

- Spark MCP: `http://localhost:8002/mcp` from the host; `http://spark-mcp:8000/mcp` from a container on `spark-lakehouse-network`.
- MinIO MCP: `http://localhost:8003/mcp` from the host; `http://minio-mcp:8001/mcp` from a container on `spark-lakehouse-network`.

Spark MCP exposes catalog discovery, schema inspection and bounded read-only SELECT queries. MinIO MCP exposes allowlisted bucket/object discovery, metadata and bounded text reads. Writes are disabled by default and can be enabled only through explicit configuration. Create the configured `lakehouse` bucket in MinIO before using the MinIO MCP tools. See [the MCP integration guide](mcp/README.md) for tool contracts, client configuration and security boundaries.

## Useful commands

```bash
docker compose ps
docker compose logs -f spark-master
docker compose logs -f spark-worker-1 spark-worker-2
docker compose logs -f jupyter
docker compose exec jupyter bash
docker compose exec ollama ollama list
docker compose down
```

`docker compose down` preserves named volumes. `docker compose down -v` deletes persisted data, notebooks configuration, model cache and MinIO data. Use the latter only when you intentionally want a clean reset.

## Security notes

- Published ports are bound to `127.0.0.1`; do not expose this development stack directly to an untrusted network.
- Change the Jupyter token and MinIO root password in `.env`.
- `.env` is ignored by Git; never commit credentials.
- This is a local development topology, not a hardened production deployment.
- Ollama is reachable from other containers at `http://ollama:11434`.
- Spark is reachable from containers at `spark://spark-master:7077`.

## MinIO-backed Lakehouse data path

The current Compose configuration includes the Spark S3A integration:
- The custom Spark runtime adds `hadoop-aws:3.3.4` and `aws-java-sdk-bundle:1.12.262`, matching the Hadoop 3.3.4 client in the pinned Spark base image.
- Spark uses the MinIO endpoint `http://minio:9000`, path-style S3 requests and environment-injected credentials.
- The dedicated Spark identity is passed to Jupyter, Spark MCP and both worker containers.
- The `lakehouse` bucket is the canonical data lake. Raw, Bronze, Silver and Gold are object prefixes; Parquet is the baseline data format.
- Run `./scripts/validate.sh` after rebuilding. The S3A integration check writes and reads a small distributed Parquet dataset and removes its unique validation prefix.

**Runtime acceptance is still required on each host.** A committed Compose configuration does not prove that the image has been rebuilt, the service account is correctly provisioned, or the round-trip test passes. See [the S3A/MinIO runbook](storage/MINIO-SPARK-S3A.md).

The shared local `/lakehouse` bind mount remains temporarily for legacy scratch/import workflows only; it is not the canonical lake. CrewAI and Streamlit are not started in this phase. Spark MCP and MinIO MCP remain separate agent-facing interfaces; no agent runtime is bundled.
