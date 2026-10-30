# Spark Lakehouse Agent Platform

A local Docker Compose foundation for a multi-agent retail analytics lakehouse.

Phase 1 services: Apache Spark Standalone (one master and two workers), JupyterLab, Ollama, and MinIO.

## Quick start

1. Copy `.env.example` to `.env`.
2. Change `JUPYTER_TOKEN` and `MINIO_ROOT_PASSWORD`.
3. Run the setup and startup scripts for your operating system.
4. Validate the cluster and pull Qwen into Ollama.

See [docs/PHASE-1.md](docs/PHASE-1.md) for full instructions.

## Scope

Phase 1 establishes infrastructure only. Retail ingestion, Bronze/Silver/Gold transformations, data-quality checks, agent orchestration and dashboards are future phases.

Do not commit `.env` or real credentials.