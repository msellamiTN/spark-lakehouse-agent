# Architecture diagrams

This directory contains the architecture assets for the Spark Lakehouse Agent Platform.

## Diagram catalogue

| Asset | Format | Purpose | Status |
|---|---|---|---|
| [Phase 1 deployment architecture](phase-1-architecture.svg) | SVG | Deployment topology for Spark, MinIO, both MCP servers, agent endpoints and storage boundaries | Current Phase 1 baseline |

The editable Mermaid diagrams are maintained in the root [README](../../README.md):
- Deployment topology: Spark, JupyterLab, Ollama, MinIO, Spark MCP, MinIO MCP, network boundaries, host endpoints and mounts.
- Lakehouse lifecycle: source-to-consumption data progression.

## Source-of-truth rules

1. **Runtime configuration is authoritative.** Verify services, images, ports, mounts, health checks and environment variables against `docker-compose.yml`, the Dockerfiles and `.env.example`.
2. **Separate deployed capability from roadmap.** A running container does not imply application integration. Dashed connectors represent future or not-yet-configured integration.
3. **Keep deployment and logical views distinct.** The SVG communicates the deployed topology. Mermaid communicates editable relationships and processing flows.
4. **Do not imply production readiness.** These diagrams describe a local development environment, not a production security or high-availability design.
5. **Update both views together.** When a service, port, mount, dependency or phase boundary changes, update the SVG and Mermaid diagram in the same change.
6. **Preserve accessibility.** SVG files must include a descriptive `title` and `desc`, use legible labels, and remain readable at normal document scale.

## Phase 1 accuracy notes

- Spark MCP is a read-only Streamable HTTP interface to Spark catalog discovery and bounded SELECT queries.
- MinIO MCP is a scoped Streamable HTTP interface to allowlisted object storage; text writes are disabled by default.
- MCP endpoints are loopback-published for local clients; compatible agent runtimes are not bundled in Phase 1.

- Spark Standalone consists of one master and two workers.
- JupyterLab connects to Spark using `spark://spark-master:7077`.
- Spark workers and Jupyter share the host-mounted `/lakehouse` directory.
- Ollama is deployed on the Compose network. Agent/application integration is not implemented in Phase 1.
- MinIO is deployed with persistent storage. Spark S3A dependencies, bucket provisioning and Spark-to-MinIO access are deferred to Phase 2.
- All published service ports are bound to loopback (`127.0.0.1`) in the Compose configuration.

## Change checklist

Before merging an architecture change:

- [ ] Confirm the change against Compose, Dockerfiles and environment configuration.
- [ ] Update the Mermaid deployment diagram.
- [ ] Update the SVG deployment diagram.
- [ ] Re-check Phase 1 / future-phase labels and connector semantics.
- [ ] Verify endpoint and port labels.
- [ ] Review SVG title, description, legibility and GitHub rendering.
