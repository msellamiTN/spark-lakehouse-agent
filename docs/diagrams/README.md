# Architecture diagrams

## Architecture documentation

- [Platform architecture — deployment, data flow, security boundaries and decisions](../ARCHITECTURE.md)
- [Operations troubleshooting and field notes](../TROUBLESHOOTING.md)
- [Default Docker Compose + Tailscale deployment](../mcp/DOCKER-TAILSCALE-STUDENT-LAB.md)

## Diagram catalogue

| Asset | Format | Purpose | Status |
|---|---|---|---|
| [Phase 1 deployment architecture](phase-1-architecture.svg) | SVG | Deployment topology and persistence boundaries | Current Phase 1 baseline |
| Architecture views | Mermaid | Deployment, data lifecycle and operational lifecycle | Maintained in [ARCHITECTURE.md](../ARCHITECTURE.md) |

## Source-of-truth rules

1. Runtime configuration is authoritative. Verify services, images, ports, mounts, health checks and environment variables against docker-compose.yml, Dockerfiles and .env.example.
2. Separate deployed capability from roadmap. Dashed connectors represent future or unconfigured integration.
3. Keep deployment and logical views distinct.
4. Do not imply production readiness. These diagrams describe a single-host training/lab environment.
5. Update diagrams and runbooks when services, ports, mounts, dependencies or phase boundaries change.
6. SVG files must include descriptive title and desc elements and remain legible.

## Phase 1 accuracy notes

- Spark MCP is a read-only Streamable HTTP interface to catalog discovery and bounded SELECT queries.
- MinIO MCP is scoped to allowlisted object storage; text writes are disabled by default.
- Spark Standalone has one master and two workers.
- JupyterLab connects to spark://spark-master:7077.
- Spark workers and Jupyter share the host-mounted /lakehouse directory.
- Ollama is deployed; agent/application integration is not implemented in Phase 1.
- MinIO is persistent. Spark S3A dependencies, bucket provisioning and Spark-to-MinIO access are Phase 2.
- Published service ports bind to loopback; remote MCP access uses Tailscale Serve.

## Change checklist

- [ ] Verify changes against Compose, Dockerfiles and environment configuration.
- [ ] Update architecture and troubleshooting documentation.
- [ ] Re-check phase labels and connector semantics.
- [ ] Verify endpoint and port labels.
- [ ] Review SVG title, description, legibility and GitHub rendering.
