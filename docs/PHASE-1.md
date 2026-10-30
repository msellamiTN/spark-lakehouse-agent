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

## Requirements

- Docker Desktop with Docker Compose v2, or Docker Engine + Compose plugin.
- 16 GB RAM minimum recommended for a light local run; 32 GB preferred.
- At least 20 GB free disk space if pulling the Qwen model.
- Virtualization enabled when using Docker Desktop on Windows.

The default worker allocation is 2 cores and 3 GiB per worker. Tune `.env` to fit the host. Leave memory for Docker, Ollama and the operating system.

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

## Important scope boundary

MinIO is deployed and persistent in Phase 1. Spark's S3A connector and MinIO bucket integration are deliberately deferred until Phase 2, where Hadoop AWS and AWS SDK dependency versions will be aligned with the Spark distribution. Phase 1 writes Parquet to the shared local `/lakehouse` volume.

CrewAI and Streamlit are not started in Phase 1; they will be added after the Spark and storage foundation passes validation. The Spark MCP and MinIO MCP services are available as agent-facing interfaces, but no agent runtime is bundled.
