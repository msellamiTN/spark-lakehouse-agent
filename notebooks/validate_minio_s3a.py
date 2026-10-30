#!/usr/bin/env python3
"""End-to-end Spark S3A ↔ MinIO validation using a disposable test prefix."""

import os
import sys
from uuid import uuid4

from pyspark.sql import SparkSession


BUCKET = os.getenv("LAKEHOUSE_BUCKET", "lakehouse")
TEST_PREFIX = os.getenv("S3A_VALIDATION_PREFIX", "_system/validation")
MASTER = os.getenv("SPARK_MASTER", "spark://spark-master:7077")
EXPECTED_HADOOP_VERSION = "3.3.4"


def main() -> int:
    if not os.getenv("AWS_ACCESS_KEY_ID") or not os.getenv("AWS_SECRET_ACCESS_KEY"):
        raise RuntimeError(
            "Spark S3A credentials are missing. Configure SPARK_S3A_ACCESS_KEY "
            "and SPARK_S3A_SECRET_KEY in .env; do not use MinIO root credentials."
        )

    spark = (
        SparkSession.builder
        .appName("spark-minio-s3a-validation")
        .master(MASTER)
        .config("spark.executor.instances", "2")
        .getOrCreate()
    )

    test_uri = f"s3a://{BUCKET}/{TEST_PREFIX}/run-{uuid4().hex}"
    jvm = spark._jvm
    hadoop_conf = spark.sparkContext._jsc.hadoopConfiguration()
    test_path = jvm.org.apache.hadoop.fs.Path(test_uri)
    fs = None

    try:
        hadoop_version = jvm.org.apache.hadoop.util.VersionInfo.getVersion()
        if hadoop_version != EXPECTED_HADOOP_VERSION:
            raise RuntimeError(
                f"Expected Hadoop {EXPECTED_HADOOP_VERSION} to match hadoop-aws; "
                f"runtime reports Hadoop {hadoop_version}."
            )

        # Fail early with a clear message if the S3A classes are absent.
        jvm.java.lang.Class.forName("org.apache.hadoop.fs.s3a.S3AFileSystem")
        endpoint = hadoop_conf.get("fs.s3a.endpoint")
        if endpoint != "http://minio:9000":
            raise RuntimeError(f"Unexpected S3A endpoint: {endpoint!r}")

        fs = test_path.getFileSystem(hadoop_conf)
        source = spark.createDataFrame(
            [(1, "raw-to-bronze"), (2, "bronze-to-silver"), (3, "silver-to-gold")],
            ["id", "stage"],
        ).repartition(2)

        source.write.mode("error").parquet(test_uri)
        restored = spark.read.parquet(test_uri)
        rows = sorted((row["id"], row["stage"]) for row in restored.collect())

        expected = [
            (1, "raw-to-bronze"),
            (2, "bronze-to-silver"),
            (3, "silver-to-gold"),
        ]
        if rows != expected:
            raise AssertionError(f"Read-back mismatch: {rows!r}")

        print("PASS: Hadoop/S3A dependency alignment:", hadoop_version)
        print("PASS: S3A endpoint:", endpoint)
        print("PASS: Spark executors wrote Parquet to MinIO and read it back.")
        print("PASS: Rows verified:", len(rows))
        print("Test prefix:", test_uri)
        return 0
    finally:
        if fs is not None and fs.exists(test_path):
            if not fs.delete(test_path, True):
                print(f"WARNING: Could not remove validation prefix {test_uri}", file=sys.stderr)
            else:
                print("Validation prefix cleaned up.")
        spark.stop()


if __name__ == "__main__":
    raise SystemExit(main())
