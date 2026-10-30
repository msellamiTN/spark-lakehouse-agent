# Spark Lakehouse Agent Platform

A local, Docker Compose-based foundation for a multi-agent retail analytics lakehouse.

**Phase 1 services:** Apache Spark Standalone (1 master + 2 workers), JupyterLab, Ollama, and MinIO.

## Quick start

1. Copy `.env.example` to `.env`.
2. Change `JUPYTER_TOKEN` and `MINIO_ROOT_PASSWORD`.
3. Run the setup and startup scripts for your OS.
4. Validate the cluster and pull Qwen into Ollama.

See [docs/PHASE-1.md](docs/PHASE-1.md) for complete instructions.

## Architecture direction

- Bronze / Silver / Gold lakehouse layers.
- Classic Hadoop `retail_db` as the first business dataset.
- Future CrewAI agents: Supervisor, Data Engineer, Data Analyst, and Data Visualization Engineer.
- Local Qwen model hosted by Ollama.
- Streamlit + Plotly dashboards.

## Phase boundaries

Phase 1 establishes infrastructure only. Phase 2 adds retail data ingestion, lakehouse transformations, schemas and data quality. Agent orchestration and dashboards follow in subsequent phases.

## Security

Do not commit `.env` or real credentials. This is a local development topology, not a hardened production deployment.
