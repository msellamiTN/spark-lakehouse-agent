ARG SPARK_BASE_IMAGE=apache/spark:3.5.6-scala2.12-java17-python3-ubuntu
FROM ${SPARK_BASE_IMAGE}

ARG HADOOP_VERSION=3.3.4
ARG AWS_SDK_BUNDLE_VERSION=1.12.262

USER root

# S3A must match the Hadoop client version bundled with this Spark distribution.
# Hadoop 3.3.4's hadoop-aws POM pins AWS SDK v1 bundle 1.12.262.
RUN set -eux; \
    test -f "/opt/spark/jars/hadoop-client-api-${HADOOP_VERSION}.jar"; \
    test -f "/opt/spark/jars/hadoop-client-runtime-${HADOOP_VERSION}.jar"; \
    python3 - <<'PY'
from pathlib import Path
from urllib.request import urlretrieve

artifacts = [
    (
        "https://repo.maven.apache.org/maven2/org/apache/hadoop/"
        "hadoop-aws/${HADOOP_VERSION}/hadoop-aws-${HADOOP_VERSION}.jar",
        "/opt/spark/jars/hadoop-aws-${HADOOP_VERSION}.jar",
    ),
    (
        "https://repo.maven.apache.org/maven2/com/amazonaws/"
        "aws-java-sdk-bundle/${AWS_SDK_BUNDLE_VERSION}/"
        "aws-java-sdk-bundle-${AWS_SDK_BUNDLE_VERSION}.jar",
        "/opt/spark/jars/aws-java-sdk-bundle-${AWS_SDK_BUNDLE_VERSION}.jar",
    ),
]
for url, destination in artifacts:
    path = Path(destination)
    if not path.exists():
        print(f"Downloading {path.name}")
        urlretrieve(url, path)
    if path.stat().st_size < 1_000_000:
        raise RuntimeError(f"Unexpectedly small dependency: {path}")
PY
    chown spark:spark "/opt/spark/jars/hadoop-aws-${HADOOP_VERSION}.jar" \
        "/opt/spark/jars/aws-java-sdk-bundle-${AWS_SDK_BUNDLE_VERSION}.jar"

USER spark

# The base Spark distribution supplies PySpark and Py4J; keep its versions aligned.
ENV PYTHONUNBUFFERED=1 \
    PYSPARK_PYTHON=python3 \
    SPARK_HOME=/opt/spark
