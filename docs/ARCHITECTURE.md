# Spark Lakehouse Agent Platform — Architecture

> **Deployment baseline:** OVH Ubuntu · Docker Compose v2 · Spark Standalone · JupyterLab · Ollama · MinIO · Spark MCP · MinIO MCP · Nginx · Tailscale Serve.  
> **Architectural intent:** private-by-default ingress, explicit trust boundaries, persistent state, scoped agent capabilities, and an honest separation between deployed features and roadmap integrations.

## 1. Executive deployment view

The platform is a single-host training and engineering environment. Compose manages service lifecycle; a private Docker bridge provides east-west connectivity; Tailscale Serve provides tailnet-only HTTPS ingress; Nginx routes requests to separate MCP servers.

### Canonical visual architecture

The following **hand-authored SVG deployment view is the primary architecture artifact**. It is designed for architecture reviews and documentation export; Mermaid diagrams below are supporting editable views for selected flows, not a substitute for the full deployment drawing.

![Spark Lakehouse Agent Platform — Phase 1 professional deployment architecture](diagrams/phase-1-architecture.svg)

[Open the SVG at full resolution](diagrams/phase-1-architecture.svg)


~~~mermaid
flowchart TB
  subgraph CLIENTS["Learners and agent clients"]
    USER["Engineer / learner"]
    HOST["MCP client / IDE / agent"]
    TSCLIENT["Tailscale client"]
    USER --> HOST --> TSCLIENT
  end
  TSCLIENT -->|"Private HTTPS · TCP 443"| TS
  subgraph OVH["OVH Ubuntu · Docker Compose"]
    subgraph EDGE["Ingress plane · shared network namespace"]
      TS["Tailscale userspace container"]
      SERVE["Tailscale Serve · HTTPS"]
      NGINX["Nginx MCP gateway"]
      TS --> SERVE --> NGINX
    end
    subgraph APP["Application plane · private Docker bridge"]
      SMCP["Spark MCP · read-only"]
      MMCP["MinIO MCP · bucket/prefix scoped"]
      SPARK["Spark master + 2 workers"]
      JUPYTER["JupyterLab"]
      MINIO["MinIO S3 API"]
      OLLAMA["Ollama"]
      NGINX -->|"/spark/mcp"| SMCP
      NGINX -->|"/minio/mcp"| MMCP
      SMCP --> SPARK
      JUPYTER --> SPARK
      MMCP --> MINIO
    end
    subgraph PERSIST["Persistence plane"]
      LAKE[("Host mount: lakehouse/")]
      MNV[("minio_data")]
      OLV[("ollama_models")]
      JCV[("jupyter_config")]
      TSV[("tailscale_state")]
    end
    SPARK --> LAKE
    JUPYTER --> LAKE
    MINIO --> MNV
    OLLAMA --> OLV
    JUPYTER --> JCV
    TS --> TSV
  end
~~~

### Network exposure contract

| Endpoint | Exposure | Purpose |
|---|---|---|
| Tailscale Serve TCP 443 | Tailnet only | Remote MCP ingress |
| /spark/mcp | Tailnet only | Spark catalog and bounded read-only SQL |
| /minio/mcp | Tailnet only | Allowlisted MinIO object operations |
| Host ports 8002 / 8003 | 127.0.0.1 only | Local MCP diagnostics |
| Gateway port 8088 | 127.0.0.1 only | Health diagnostics |
| Spark UI, Jupyter, MinIO, Ollama | 127.0.0.1 only | Administrator access |

🔐 **Invariant:** do not bind services to 0.0.0.0 on the host, publish MCP ports publicly, or enable Tailscale Funnel.

## 2. Service architecture and responsibilities

| Plane | Components | Responsibility | Design rule |
|---|---|---|---|
| Access / ingress | Tailscale client, Tailscale container, Serve, Nginx | Private transport and path routing | Only TCP 443 remotely reachable |
| MCP application | Spark MCP, MinIO MCP | Translate tool calls into bounded backend operations | Independent tool and permission surfaces |
| Compute | Spark master, two workers | Distributed Spark execution | Internal Spark RPC; UI loopback only |
| Interactive engineering | JupyterLab | Notebook development and Spark client | Token protected; loopback only |
| Object storage | MinIO | S3-compatible object API | Persistent volume; dedicated identities |
| Model runtime | Ollama | Local model serving | No assumption of Phase 1 agent integration |
| Persistence | Bind mount and named volumes | Durable data and service state | Never delete volumes for routine troubleshooting |

| Service | Internal endpoint | Persistence |
|---|---|---|
| Spark master | spark-master:7077 | lakehouse bind mount |
| Spark workers | spark-worker-1, spark-worker-2 | lakehouse bind mount |
| JupyterLab | jupyter:8888 | jupyter_config and lakehouse mounts |
| Ollama | ollama:11434 | ollama_models |
| MinIO | minio:9000; console :9001 | minio_data |
| Spark MCP | spark-mcp:8000/mcp | Stateless |
| MinIO MCP | minio-mcp:8001/mcp | Stateless |
| Nginx gateway | :8080 in shared namespace | Read-only config mount |
| Tailscale | Shared namespace with gateway | tailscale_state |

**Compose topology note:** Tailscale uses network_mode service:mcp-gateway. It shares the gateway network namespace by design. Do not configure a separate container hostname for this sidecar; TS_HOSTNAME sets the Tailscale device name.

## 3. Logical data lifecycle and phase boundary

~~~mermaid
flowchart LR
  SRC["Training / sample data"] --> ING["Notebook or Spark ingestion"]
  ING --> FS[("Shared lakehouse filesystem")]
  FS --> RAW["Raw"] --> BRZ["Bronze"] --> SLV["Silver"] --> GLD["Gold"]
  GLD --> CON["Analytics / consumers"]
  subgraph PHASE2["Phase 2 — planned, not deployed by Phase 1"]
    S3A["Spark S3A + compatible Hadoop AWS dependencies"]
    BUCKET[("MinIO lakehouse bucket")]
    S3A -. "planned object-store path" .-> BUCKET
  end
~~~

⚠️ **Critical distinction:** Phase 1 Spark and Jupyter share the host-mounted /lakehouse path. MinIO is deployed independently with persistent storage and exposed through MinIO MCP. Spark S3A dependencies, bucket provisioning automation, and direct Spark-to-MinIO read/write integration are Phase 2. Co-deployment of Spark and MinIO does not mean Spark is already integrated with MinIO.

Storage domains:
- **Filesystem workspace:** lakehouse/raw, bronze, silver, gold, checkpoints.
- **Object storage:** MinIO buckets, initially allowlisted as lakehouse; bucket and identity permissions require explicit provisioning.
- **Service state:** MinIO, Ollama, Jupyter configuration, and Tailscale named volumes.

## 4. MCP capability boundaries

### Spark MCP

Connects to spark://spark-master:7077. It is a catalog and bounded query interface, not a general Spark shell.

| Tools | Capability | Guardrail |
|---|---|---|
| get_spark_session_info | Session/cluster metadata | No caller SQL |
| list_databases, list_tables | Catalog discovery | Identifier validation |
| describe_table | Schema inspection | Identifier validation |
| run_readonly_query | Bounded SELECT | Single statement, row cap, rejects DDL/DML/comments |

### MinIO MCP

Connects to http://minio:9000. list_buckets checks only configured allowlist entries; it is not account-wide bucket enumeration.

| Tool | Capability | Guardrail |
|---|---|---|
| list_buckets | Check configured bucket accessibility | MINIO_MCP_ALLOWED_BUCKETS |
| list_objects | Paginated object listing | Bucket allowlist and bounded page size |
| get_object_metadata | Object metadata | Allowlist and safe object key |
| read_text_object | Bounded UTF-8 text read | Content type/suffix and byte limit |
| write_text_object | Optional text artifact write | Disabled by default; prefix and size/type checks |

**Layered authorization:** Tailscale grants control network reachability; Nginx routes; MCP code validates tool inputs; MinIO IAM/service-account policy enforces object permissions. No layer replaces another.

## 5. Security architecture

1. **Private ingress:** Tailscale Serve is tailnet-only; Funnel is disabled.
2. **No public service listeners:** published Docker ports bind to 127.0.0.1.
3. **Secret handling:** credentials and auth keys stay in local .env, excluded from Git. Never put them in notebooks, prompts, logs, or screenshots.
4. **MinIO identity:** use a dedicated MCP service account, not root. Grant bucket-scoped List/Get and optional Put only under agent-outputs/*.
5. **Spark query safety:** preserve read-only validation and bounded result sizes.
6. **Student isolation:** Tailscale ACLs do not isolate Spark sessions, objects, or tool permissions. Per-team identities/buckets and Spark authorization are required before sensitive multi-tenant use.
7. **Persistence safety:** docker compose down -v deletes named volumes, including MinIO data and Tailscale identity.
8. **Operational classification:** single-host training/lab design; not HA or production-hardened multi-tenant architecture.

## 6. Operational lifecycle

~~~mermaid
flowchart TD
  A["Review secrets and .env"] --> B["Compose config validation"]
  B --> C["Start services"]
  C --> D["Check health and logs"]
  D --> E["Check Tailscale status and Serve"]
  E --> F["MCP initialize and tools/list"]
  F --> G["Validate backend permissions"]
  G --> H["Run workload tests"]
  H --> I["Authorize student access"]
~~~

~~~bash
docker compose config --quiet
docker compose ps
docker compose logs --tail=100 tailscale mcp-gateway spark-mcp minio-mcp
docker compose exec tailscale tailscale status
docker compose exec tailscale tailscale serve status
./scripts/validate.sh
~~~

## 7. Architecture decisions

| Decision | Rationale | Consequence |
|---|---|---|
| Single Compose stack | Reproducible lab with minimal host prerequisites | Single-host failure domain |
| Tailscale userspace container | Avoid host Tailscale and privileged TUN dependency | Shared gateway network namespace |
| Nginx path gateway | Stable host and separate MCP paths | Preserve streaming/SSE behaviour |
| Separate MCP servers | Independent capabilities and permissions | Validate both tool contracts |
| Loopback host publishing | Reduce accidental public exposure | Admin access via host or SSH tunnel |
| MinIO named volume | Durable objects across container recreation | Backup/restore is operator responsibility |
| Shared local lakehouse in Phase 1 | Simple Spark/Jupyter workflow | Not equivalent to S3 integration |

## 8. Change-control checklist

- [ ] Verify changes against docker-compose.yml, Dockerfiles, .env.example, and implementation.
- [ ] Update deployment and data-flow diagrams.
- [ ] Update service inventory, endpoint table, and persistence mapping.
- [ ] Label roadmap integrations explicitly.
- [ ] Re-check loopback bindings, Tailscale Serve paths, and Funnel state.
- [ ] Update [troubleshooting](TROUBLESHOOTING.md).
- [ ] Validate Markdown/Mermaid rendering and relevant deployment tests.
