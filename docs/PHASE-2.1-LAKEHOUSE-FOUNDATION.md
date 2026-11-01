# Phase 2.1 — Lakehouse Foundation

**Status:** design and contract baseline proposed by this pull request. Runtime ingestion and transformation are not yet enabled by this document.

## 1. Objective

Establish a stable, testable data contract for the Lakehouse before adding ingestion pipelines or agent write capabilities. This phase formalizes object naming, Medallion-zone semantics, dataset metadata, schema contracts, and automated validation.

The existing Phase 1 storage and security architecture remains authoritative:

- MinIO bucket: lakehouse (one canonical bucket).
- Spark 3.5.6 + Hadoop S3A: distributed data processing and Parquet I/O.
- Object zones are prefixes, not separate buckets or local directories.
- Spark uses its dedicated bucket-scoped service account.
- MinIO MCP uses a separate identity; writes remain disabled by default and, if explicitly enabled, are restricted to agent-outputs/.
- The local ./lakehouse:/lakehouse bind mount is transitional scratch/import storage, not the canonical Lakehouse.

## 2. Scope and non-goals

### Included

1. Canonical object-key and dataset naming conventions.
2. Raw, Bronze, Silver, Gold, checkpoint, quarantine and metadata prefix semantics.
3. A versioned JSON Schema for dataset contracts.
4. A representative retail transactions contract.
5. A dependency-free contract validation command and unit tests.
6. CI validation for contracts and tests.
7. Architecture and operational documentation.

### Explicitly deferred

- Production ingestion jobs and scheduling.
- Schema registry or metastore deployment.
- Delta Lake or Apache Iceberg transaction semantics.
- Streaming ingestion and exactly-once guarantees.
- Data catalog UI, lineage service and data-quality platform.
- Per-user or per-team authorization and isolation.
- Enabling MinIO MCP writes or changing MinIO IAM policies.

Parquet is a file format, not a table transaction protocol. Concurrent writers, atomic table commits, updates/deletes and time travel are not provided by plain Parquet alone.

## 3. Logical architecture

See the editable Mermaid diagram at diagrams/phase-2-lakehouse-foundation.mmd.

~~~text
s3a://lakehouse/
├── raw/<source>/<dataset>/                  # Immutable source landing
├── bronze/<domain>/<dataset>/               # Source-aligned, replayable Parquet
├── silver/<domain>/<dataset>/               # Validated and conformed Parquet
├── gold/<product>/<dataset>/                # Consumer-oriented data products
├── checkpoints/<pipeline>/<run-or-query>/   # Streaming state; isolated from tables
├── quarantine/<domain>/<dataset>/           # Rejected records and diagnostics
├── metadata/contracts/<domain>/<dataset>/  # Versioned dataset contracts
├── metadata/schemas/<domain>/<dataset>/     # Schema artifacts
└── agent-outputs/<agent-or-run>/            # Optional, separately governed artifacts
~~~

Prefixes are logical object-key namespaces. They do not need to be pre-created as directories in MinIO; object writes create the keys.

## 4. Zone contract

| Zone | Meaning | Allowed content | Mutation policy |
|---|---|---|---|
| Raw | Source landing and replay boundary | Original CSV, JSON, Parquet or source payloads; source metadata | Append new immutable ingestion objects; do not overwrite source objects |
| Bronze | Parsed and traceable source-aligned data | Parquet with ingestion metadata and explicit schema | Rebuild only through controlled pipeline runs; use run-scoped staging |
| Silver | Validated, deduplicated and conformed domain data | Parquet with quality outcomes and standardized types | Publish only after validation |
| Gold | Business-ready data products | Parquet aggregates, dimensions, facts and features | Product-owner governed publication |
| Checkpoints | Processing-engine state | Spark checkpoint files only | Owned by one pipeline/query; never mix with table data |
| Quarantine | Invalid or rejected data | Rejected rows/files plus reason metadata | Restricted access and retention |
| Metadata | Contracts, schemas and manifests | JSON and documentation | Version-controlled; no credentials or personal secrets |
| Agent outputs | Agent-generated artifacts | Bounded, non-authoritative outputs | Optional MCP write scope; never treated as curated data by default |

Raw preservation is a data-engineering policy, not an immutable-storage guarantee. Enforce retention, versioning or object-lock separately if regulatory immutability is required.

## 5. Naming and partitioning

- Use lowercase ASCII snake_case for domain, source, dataset, product, field and partition names.
- A dataset identifier is stable and independent of physical file names: <domain>.<dataset>.
- Use source-oriented paths for Raw: raw/<source>/<dataset>/.
- Use domain-oriented paths for Bronze and Silver: <zone>/<domain>/<dataset>/.
- Use product-oriented paths for Gold: gold/<product>/<dataset>/.
- Use Hive-style partition keys, for example transaction_date=2026-11-01/.
- Partition only on columns used for common filtering and with sufficient cardinality balance. Avoid high-cardinality identifiers (customer IDs, transaction IDs) as partitions.
- Do not encode run IDs into stable table roots. Use a staging/run prefix for an individual publication and a documented publish step.
- Keep file names generated by Spark; do not assume one file per partition.

A path template in a contract uses named placeholders, such as {ingest_date}. It is a template, not a directly readable S3A URI until placeholders are resolved.

## 6. Dataset contract

The JSON Schema is docs/contracts/schema/dataset-contract.schema.json. The initial example is docs/contracts/datasets/retail-transactions.json.

Every contract records:

- Stable dataset ID, semantic version, domain, owner and description.
- Source location template and source serialization format.
- Target zone, storage format and target location template.
- Primary key and partition columns.
- Ordered field definitions, logical types, nullability and descriptions.
- Quality rules that can be implemented by a later ingestion/quality pipeline.

Contract versioning is independent from the application release. A breaking field removal, type change or primary-key semantic change requires a major contract version. Additive nullable fields are generally minor; documentation-only changes are patch-level. Producers and consumers must still test compatibility rather than infer it solely from the version number.

## 7. Data publication rules

The future ingestion implementation must:

1. Validate the contract before reading or writing data.
2. Preserve source objects in Raw and record source URI, ingestion timestamp and run identifier.
3. Write to a unique staging prefix rather than overwrite a published dataset in place.
4. Validate schema, primary-key uniqueness and required-field nullability before promotion.
5. Publish only validated output to the stable target prefix.
6. Record a manifest containing contract version, source objects, row counts, rejected counts, run ID and code version.
7. Make retries idempotent or explicitly document at-least-once behavior.
8. Keep checkpoints and quarantine separate from curated data.
9. Never pass MinIO root credentials to Spark, notebooks, MCP servers or agents.

Plain Parquet does not provide an atomic multi-file table commit. A future publication protocol must account for readers observing partial output (for example, write a versioned output prefix and publish a manifest/pointer only after validation). Do not claim ACID semantics until a transactional table format and compatible catalog are deployed.

## 8. Security and governance

The contract and directory conventions do not grant access. Authorization remains enforced by MinIO service-account policies and MCP tool boundaries.

Current Phase 1 policy scope is bucket-wide for the Spark service identity and bucket-read for MinIO MCP. The optional MCP write policy grants PutObject only under lakehouse/agent-outputs/*. This PR does not narrow or expand those policies.

Before untrusted multi-team data is introduced, design per-domain/per-team access controls, credential rotation, audit retention, data classification and Spark-side authorization. Tailscale network access is not data-level authorization.

Do not put credentials, tokens, personal data samples or production extracts in contracts or Git.

## 9. Validation

Run locally:

~~~bash
python3 scripts/validate_lakehouse_contracts.py
python3 -m unittest discover -s tests -v
~~~

CI runs both commands on pull requests and pushes to main.

This validation checks the checked-in contract documents. It does not prove that MinIO objects exist, that S3A access works on a deployment, or that runtime IAM policies are correct. Continue to use ./scripts/validate.sh for infrastructure acceptance on the OVH host.

## 10. Phase 2.1 acceptance checklist

- [ ] Contract JSON Schema is reviewed and versioned.
- [ ] Retail transactions example passes the contract validator.
- [ ] Unit tests cover malformed contracts and path/partition violations.
- [ ] CI passes on GitHub.
- [ ] Architecture documentation distinguishes canonical MinIO storage from local scratch.
- [ ] Existing Phase 1 MinIO identities, policies, bucket and Compose services remain unchanged.
- [ ] OVH runtime validation is run separately before any production-like ingestion.

## 11. Next milestone

Phase 2.2 will implement a controlled CSV/JSON/Parquet ingestion path for the retail example. It must consume the contract defined here, preserve Raw input, write Bronze Parquet through Spark S3A, validate results, and produce a run manifest. It will be reviewed as a separate change.
