# Spark S3A ↔ MinIO Lakehouse integration

This runbook configures MinIO as the canonical Lakehouse object store for the Spark 3.5.6 Standalone cluster. Raw, Bronze, Silver and Gold are prefixes in the existing `lakehouse` bucket. Spark accesses them through Hadoop S3A; the local `./lakehouse` bind mount remains only as a legacy scratch/import workspace and is not the canonical data lake.

## 1. Runtime and dependency alignment

The custom Spark image is built from the pinned Apache Spark base image and adds:

| Component | Pinned version | Reason |
|---|---:|---|
| Apache Spark | 3.5.6 | Existing cluster runtime |
| Hadoop client | 3.3.4 | Version bundled with this Spark image; build fails if the expected client JARs are absent |
| `hadoop-aws` | 3.3.4 | Must match Hadoop client exactly |
| `aws-java-sdk-bundle` | 1.12.262 | Dependency declared by `hadoop-aws:3.3.4` |
| `wildfly-openssl` | 1.0.7.Final | Optional runtime dependency declared by `hadoop-aws:3.3.4`; JSSE is explicitly selected, so native OpenSSL acceleration is not used |

Do not upgrade `hadoop-aws` independently. Hadoop's S3A connector and Hadoop client libraries must use identical versions; mismatches can cause linkage errors such as `NoSuchMethodError`. The build intentionally checks the Hadoop client JAR names before downloading the S3A dependencies.

The image is built first by `./scripts/up.sh`; that script then builds Jupyter and both MCP images against the local custom Spark image. This explicit order avoids dependent Docker builds trying to pull the not-yet-built local base image. The OVH host must be able to reach `repo.maven.apache.org` over HTTPS during the Spark image build.

## 2. MinIO bucket and credentials

The configured bucket is `lakehouse`. Create it once through the MinIO Console (`http://<OVH-host>:9001`, via your private admin access): **Object Browser → Create Bucket → lakehouse**. No shell command, `mc` client, extra service account, or additional Spark credential is required.

For the simple single-host lab profile, Compose reuses the MinIO credentials already present in `.env`:

- `MINIO_ROOT_USER` is injected as `AWS_ACCESS_KEY_ID`.
- `MINIO_ROOT_PASSWORD` is injected as `AWS_SECRET_ACCESS_KEY`.

The same values are passed to both Spark workers, Jupyter (the Spark driver), and Spark MCP (the Spark driver). The Hadoop S3A environment-variable credential provider reads them automatically. You do not need `SPARK_S3A_ACCESS_KEY`, `SPARK_S3A_SECRET_KEY`, or any manual credential-generation step. Do not duplicate the credentials in `spark-defaults.conf`.

**Security trade-off:** MinIO root credentials have administrative privileges, not bucket-scoped permissions. This is intentionally the simplest configuration for a trusted, single-user lab. Do not use this profile for untrusted students, sensitive data, or production multi-tenancy. For those cases, switch to a dedicated bucket-scoped Spark service identity or a secrets manager. Keep MinIO MCP's optional identity and tool-level allowlist separate; the Spark root credential does not change MCP's own authorization checks.

## 3. S3A configuration

The read-only configuration file `infrastructure/spark/spark-defaults.conf` sets:

- `fs.s3a.impl=org.apache.hadoop.fs.s3a.S3AFileSystem`
- `fs.s3a.endpoint=http://minio:9000` (Docker-internal endpoint)
- `fs.s3a.endpoint.region=us-east-1` (explicit signing region, matching the MinIO client configuration)
- `fs.s3a.path.style.access=true` (required for this MinIO endpoint style)
- TLS disabled only on the private Docker bridge; use HTTPS if the object endpoint crosses a network boundary
- `fs.s3a.ssl.channel.mode=default_jsse` to avoid depending on native OpenSSL compatibility
- AWS SDK environment-variable credentials provider
- Conservative connection, thread and multipart defaults

The Spark master, workers, Jupyter and Spark MCP receive the same configuration file. The workers, Jupyter driver and Spark MCP driver receive the existing MinIO root credentials through Compose environment interpolation, so executor-side and driver-side S3A operations can authenticate.

## 5. Rebuild and validate

From the repository root on the OVH host:

```bash
./scripts/up.sh
docker compose ps
```

The script builds the Spark/S3A base image first, then builds Jupyter and MCP images that inherit it, and finally starts the stack.

Then run:

```bash
./scripts/validate.sh
```

The validation suite includes `notebooks/validate_minio_s3a.py`. It:

1. Confirms the runtime Hadoop version is 3.3.4 and the S3A classes load.
2. Confirms the configured MinIO endpoint.
3. Creates a unique disposable prefix under `lakehouse/_system/validation/`.
4. Writes a small Parquet dataset from a distributed Spark DataFrame.
5. Reads the Parquet dataset back through S3A and verifies the rows.
6. Deletes only that unique validation prefix.

The test waits for MinIO readiness and uses the configured MinIO credentials to perform ListBucket, GetObject, PutObject and DeleteObject operations under the validation prefix. It does not modify Raw/Bronze/Silver/Gold datasets. A passing validation confirms the driver and distributed executor path; it does not validate production throughput, HA, catalog transactions or multi-tenant isolation.

## 6. Canonical object layout

```text
s3a://lakehouse/
├── raw/<source>/<dataset>/          # Source-aligned landing
├── bronze/<domain>/<dataset>/       # Traceable ingested datasets
├── silver/<domain>/<dataset>/       # Cleansed and conformed data
├── gold/<product>/<dataset>/        # Business-ready data products
├── checkpoints/<pipeline>/         # Streaming checkpoints
├── quarantine/<domain>/             # Rejected records
└── _system/validation/              # Disposable integration-test prefix
```

Use Parquet as the baseline file format. Plain Parquet on S3A is not transactional: do not claim ACID table guarantees. If concurrent writers, atomic table commits, schema evolution or time travel are required, select and configure a compatible table format such as Apache Iceberg or Delta Lake together with its catalog and commit protocol.

## 7. Troubleshooting

| Symptom | Likely cause | Check |
|---|---|---|
| `ClassNotFoundException: org.apache.hadoop.fs.s3a.S3AFileSystem` | S3A JAR missing from runtime | Rebuild custom Spark image; inspect `/opt/spark/jars` |
| Image build cannot download JARs | Outbound HTTPS to Maven Central is blocked | Verify the OVH host can reach `repo.maven.apache.org:443` |
| Build fails Hadoop client JAR check | Spark base image does not contain the pinned Hadoop client | Keep the Spark 3.5.6 base image or align all Hadoop/S3A versions together |
| `NoSuchMethodError` in Hadoop/AWS classes | Hadoop or AWS SDK version conflict | Keep hadoop-aws 3.3.4 and SDK bundle 1.12.262 aligned |
| `AccessDenied` / HTTP 403 | Wrong MinIO credentials or bucket policy | Confirm `.env` MinIO root credentials match the running MinIO instance; do not print them |
| `InvalidAccessKeyId` | Credentials not recognized by MinIO | Confirm the `.env` values match the MinIO instance; recreate Spark containers after changing credentials |
| `UnknownHostException: minio` | Driver not on Compose network or wrong endpoint | Use `http://minio:9000` from platform containers |
| Signature / endpoint errors | Path-style or endpoint mismatch | Keep path-style access enabled and endpoint exact |
| Driver succeeds but executor fails | Credentials not present in worker containers | Check AWS env variable presence on both workers without printing values |
| Bucket not found | `lakehouse` bucket absent or wrong endpoint | Verify bucket existence in MinIO Console; do not delete `minio_data` |

Safe credential-presence check (prints booleans only):

```bash
docker compose exec spark-worker-1 sh -lc 'test -n "$AWS_ACCESS_KEY_ID" && test -n "$AWS_SECRET_ACCESS_KEY" && echo "worker 1 credentials present"'
docker compose exec spark-worker-2 sh -lc 'test -n "$AWS_ACCESS_KEY_ID" && test -n "$AWS_SECRET_ACCESS_KEY" && echo "worker 2 credentials present"'
docker compose exec jupyter sh -lc 'test -n "$AWS_ACCESS_KEY_ID" && test -n "$AWS_SECRET_ACCESS_KEY" && echo "Jupyter credentials present"'
```

Never run `docker compose down -v` to troubleshoot S3A. It deletes persistent MinIO data and other named volumes.
