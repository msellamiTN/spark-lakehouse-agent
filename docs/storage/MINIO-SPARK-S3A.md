# Spark S3A ↔ MinIO Lakehouse integration

This runbook configures MinIO as the canonical Lakehouse object store for the Spark 3.5.6 Standalone cluster. Raw, Bronze, Silver and Gold are prefixes in the persistent `lakehouse` bucket. Spark accesses them through Hadoop S3A; the local `./lakehouse` bind mount remains a legacy scratch/import workspace, not the canonical data lake.

## 1. Runtime and dependency alignment

| Component | Pinned version | Reason |
|---|---:|---|
| Apache Spark | 3.5.6 | Cluster runtime |
| Hadoop client | 3.3.4 | Version bundled with the Spark image |
| `hadoop-aws` | 3.3.4 | Must match Hadoop client exactly |
| `aws-java-sdk-bundle` | 1.12.262 | Dependency declared by `hadoop-aws:3.3.4` |
| `wildfly-openssl` | 1.0.7.Final | Optional dependency; JSSE is explicitly selected |
| MinIO Client | `RELEASE.2025-08-13T08-35-41Z` | Pinned bootstrap client |

Do not upgrade `hadoop-aws` independently. The Hadoop client and S3A connector must use identical versions. The custom image build checks the expected Hadoop client JARs before adding the S3A dependencies.

## 2. Identity and authorization model

MinIO root credentials remain in the root-only MinIO server configuration and are used by the one-shot bootstrap/admin process. They are **not** injected into Spark, Jupyter, Spark MCP or MinIO MCP.

| Identity | Runtime consumers | Permissions |
|---|---|---|
| MinIO root | MinIO server; bootstrap/admin only | Administrative |
| `SPARKLAKEHOUSE01` | Spark workers, Jupyter driver, Spark MCP driver | Bucket-scoped list, read, write, multipart and delete operations in `lakehouse` |
| `MINIOMCPLAKEHOUSE1` | MinIO MCP only | Read-only access to `lakehouse`; optional PutObject limited to `agent-outputs/*` |

The two application identities have separate inline IAM policies. Neither policy grants account-wide bucket enumeration or access to another bucket. MinIO MCP also retains its application-level bucket allowlist, object-key validation, byte limits and write-prefix checks. IAM is an additional enforcement layer, not a replacement for those controls.

The bootstrap uses MinIO's service-account API through the pinned `mc` client. The policy attached to an access key can only restrict the permissions of its parent identity; it cannot grant permissions the parent does not have. See the MinIO Client references for [service-account creation](https://miniodocs.cc/reference/minio-mc-admin/mc-admin-user-svcacct-add) and [policy management](https://min.io/docs/minio/linux/reference/minio-mc-admin/mc-admin-policy.html).

## 3. Bootstrap and local secret files

The normal deployment entry point is:

```bash
./scripts/up.sh
```

It performs these steps in order:

1. Creates empty, private env-file placeholders so Compose can validate the project.
2. Starts only the persistent MinIO service.
3. Runs `scripts/bootstrap-minio.sh` through the temporary `minio-init` client service.
4. Waits for MinIO readiness and creates `lakehouse` only if it is absent.
5. Creates the two application access keys if they do not already exist, attaching their least-privilege policies.
6. Writes the generated credentials into local files and sets restrictive permissions.
7. Builds the Spark/S3A, Jupyter and MCP images, then starts the complete stack.

Generated files:

- `secrets/spark-s3a.env`: `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` for S3A.
- `secrets/minio-mcp.env`: `MINIO_MCP_ACCESS_KEY` and `MINIO_MCP_SECRET_KEY` for MinIO MCP.

The `secrets/` directory is ignored by Git. The bootstrap applies mode `0700` to the directory and `0600` to credential files. The temporary MinIO Client config containing the root alias is removed when the script exits. **Never commit these files, paste their contents into chat, or print their values in logs.**

The bootstrap is idempotent when the credential files and corresponding MinIO access keys both exist: it retains the existing secrets and reconciles the attached policies. If an access key already exists but its local secret file is missing, the script stops rather than silently rotating credentials or generating a new key. Recover or rotate that identity deliberately before retrying.

For production, replace local env files with a secrets manager and runtime secret injection. Local files are a pragmatic deployment mechanism for this single-host lab, not a production secrets-management solution.

## 4. Optional MinIO MCP writes

Writes are disabled by default:

```dotenv
MINIO_MCP_ALLOW_WRITES=false
MINIO_MCP_WRITE_PREFIXES=agent-outputs/
```

If writes are intentionally enabled, set `MINIO_MCP_ALLOW_WRITES=true` and keep `MINIO_MCP_WRITE_PREFIXES=agent-outputs/`. The bootstrap then reconciles a policy that grants only `s3:PutObject` under `lakehouse/agent-outputs/*`; it does not grant object deletion. Other prefixes are rejected by the bootstrap because they would not match the IAM boundary. Restart the platform after changing the setting.

## 5. S3A configuration

`infrastructure/spark/spark-defaults.conf` configures:

- `fs.s3a.impl=org.apache.hadoop.fs.s3a.S3AFileSystem`
- `fs.s3a.endpoint=http://minio:9000` on the private Docker bridge
- `fs.s3a.endpoint.region=us-east-1`
- `fs.s3a.path.style.access=true`
- TLS disabled only on the private Docker bridge
- JSSE and the AWS environment-variable credential provider

Spark workers, Jupyter and Spark MCP receive only the generated Spark service-account env file. The Spark master does not receive S3 credentials because it is the cluster control plane, not an application driver or executor.

## 6. Validation

After deployment:

```bash
docker compose ps
./scripts/validate.sh
```

The validation suite checks service health, MCP guardrail unit tests, Spark distributed execution, S3A Parquet write/read, MinIO health and Tailscale Serve. It additionally verifies that application containers do not receive root credentials and that the Spark and MinIO MCP identities can access `lakehouse` but cannot enumerate all account buckets. When MCP writes are disabled, it also verifies that the MCP identity is denied PutObject.

A successful S3A round-trip proves the driver and distributed executor path. It does not prove production throughput, high availability, transactional table commits or per-student isolation.

## 7. Canonical object layout

```text
s3a://lakehouse/
├── raw/<source>/<dataset>/
├── bronze/<domain>/<dataset>/
├── silver/<domain>/<dataset>/
├── gold/<product>/<dataset>/
├── checkpoints/<pipeline>/
├── quarantine/<domain>/
├── agent-outputs/                 # Optional MCP write prefix
└── _system/validation/             # Disposable integration-test prefix
```

Use Parquet as the baseline file format. Plain Parquet on S3A is not transactional. If concurrent writers, atomic commits, schema evolution or time travel are required, select a compatible table format such as Apache Iceberg or Delta Lake together with its catalog and commit protocol.

## 8. Troubleshooting and safety

| Symptom | Likely cause | Check |
|---|---|---|
| Compose reports missing env file | Bootstrap placeholders have not been created | Run `./scripts/up.sh`, not bare `docker compose up` on a fresh checkout |
| `AccessDenied` from Spark | Spark identity/policy mismatch | Re-run `bash ./scripts/bootstrap-minio.sh`; inspect policy and key status without printing secrets |
| `InvalidAccessKeyId` | Service account is absent, disabled or mismatched | Check `mc admin user svcacct info` using the admin bootstrap workflow |
| `ClassNotFoundException` for S3A | S3A JAR missing | Rebuild the custom Spark image |
| `NoSuchMethodError` in Hadoop/AWS | Dependency mismatch | Keep Hadoop and `hadoop-aws` at 3.3.4 and AWS SDK bundle at 1.12.262 |
| Bucket not found | Bootstrap did not complete or wrong endpoint | Check MinIO health and bucket existence; do not delete `minio_data` |

Never run `docker compose down -v` to troubleshoot S3A or MinIO. It deletes the persistent `minio_data` volume, along with other named volumes. A normal `docker compose down` preserves volumes.

This remains a single-host training/lab platform. A shared Spark service identity is not per-student data isolation; use separate buckets/identities and Spark-side authorization/session isolation before processing sensitive multi-tenant data.
