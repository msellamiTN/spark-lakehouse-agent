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

## 2. MinIO bucket and service identity

The configured bucket is `lakehouse`. It must already exist; the deployment does not create or delete buckets automatically.

Create a dedicated MinIO user/service account for Spark, for example `spark-lakehouse`, with a policy scoped to the `lakehouse` bucket. Do not use `MINIO_ROOT_USER` / `MINIO_ROOT_PASSWORD` for Spark.

An illustrative bucket-scoped policy for a single Spark pipeline identity is:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:ListBucket",
        "s3:GetBucketLocation",
        "s3:ListBucketMultipartUploads"
      ],
      "Resource": ["arn:aws:s3:::lakehouse"]
    },
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:AbortMultipartUpload",
        "s3:ListMultipartUploadParts"
      ],
      "Resource": ["arn:aws:s3:::lakehouse/*"]
    }
  ]
}
```

This grants object operations inside one bucket, not bucket administration. For stricter production isolation, split ingestion and curation identities and restrict object resources by zone prefix. Test the final policy against the deployed MinIO release and the actual Spark write mode/committer.

Keep the MinIO MCP identity separate. Its bucket allowlist and read/write policy are not a substitute for Spark's S3A identity. Agent writes remain disabled by default.

## 3. Configure local secrets

Add these values to the untracked `.env` file:

```dotenv
SPARK_S3A_ACCESS_KEY=<dedicated-spark-service-account-access-key>
SPARK_S3A_SECRET_KEY=<dedicated-spark-service-account-secret-key>
```

The Compose configuration injects these values into the Jupyter driver, Spark MCP driver, and Spark worker containers as `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`. Hadoop S3A uses the AWS SDK environment-variable credential provider. Credentials are not stored in `spark-defaults.conf`, notebooks, or Git.

Do not paste the values into chat, terminal transcripts, notebooks or logs. The startup script checks that both values are configured without printing them. For this single-host lab, Compose injects the values as container environment variables; production deployments should use Docker secrets or an external secret manager and stronger per-domain identities.

## 4. S3A configuration

The read-only configuration file `infrastructure/spark/spark-defaults.conf` sets:

- `fs.s3a.impl=org.apache.hadoop.fs.s3a.S3AFileSystem`
- `fs.s3a.endpoint=http://minio:9000` (Docker-internal endpoint)
- `fs.s3a.endpoint.region=us-east-1` (explicit signing region, matching the MinIO client configuration)
- `fs.s3a.path.style.access=true` (required for this MinIO endpoint style)
- TLS disabled only on the private Docker bridge; use HTTPS if the object endpoint crosses a network boundary
- `fs.s3a.ssl.channel.mode=default_jsse` to avoid depending on native OpenSSL compatibility
- AWS SDK environment-variable credentials provider
- Conservative connection, thread and multipart defaults

The Spark master, workers, Jupyter and Spark MCP receive the same configuration file. The workers receive the S3A credentials too, so executor-side file operations can authenticate.

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

The test waits for MinIO readiness and requires ListBucket, GetObject, PutObject and DeleteObject permissions for the validation prefix. It does not modify Raw/Bronze/Silver/Gold datasets. A passing validation confirms the driver and distributed executor path; it does not validate production throughput, HA, catalog transactions or multi-tenant isolation.

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
| `NoSuchMethodError` in Hadoop/AWS classes | Hadoop or AWS SDK version conflict | Keep hadoop-aws 3.3.4 and SDK bundle 1.12.262 aligned |
| `AccessDenied` / HTTP 403 | Spark identity policy too narrow or wrong credentials | Check service account policy and loaded env presence without printing values |
| `InvalidAccessKeyId` | Credentials not recognized by MinIO | Recreate the affected Compose containers after changing `.env` |
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
