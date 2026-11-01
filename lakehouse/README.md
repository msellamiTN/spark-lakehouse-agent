# Lakehouse workspace

The repository contains a local ./lakehouse:/lakehouse bind mount for transitional scratch and import workflows. It is **not** the canonical Lakehouse data store.

## Canonical data path

Durable data belongs in the MinIO bucket lakehouse, accessed by Spark through S3A:

~~~text
s3a://lakehouse/
├── raw/<source>/<dataset>/
├── bronze/<domain>/<dataset>/
├── silver/<domain>/<dataset>/
├── gold/<product>/<dataset>/
├── checkpoints/<pipeline>/
├── quarantine/<domain>/<dataset>/
├── metadata/contracts/<domain>/<dataset>/
└── agent-outputs/<agent-or-run>/
~~~

These are object-key prefixes, not physical directories that must be created in advance. The bucket is provisioned by scripts/bootstrap-minio.sh.

## Dataset contracts

The versioned contract schema and reference retail transactions contract are maintained under docs/contracts/. Phase 2.1 defines the object layout, contract format and semantic validation. It does not yet deploy ingestion jobs or a catalog.

Run local checks from the repository root:

~~~bash
bash scripts/validate-phase-2.1.sh
~~~

## Security boundary

- Spark writes using its dedicated MinIO service account.
- MinIO MCP remains read-only by default.
- If MCP writes are explicitly enabled, the IAM policy restricts writes to agent-outputs/.
- Never place credentials, production extracts or sensitive personal data in this workspace or Git.
