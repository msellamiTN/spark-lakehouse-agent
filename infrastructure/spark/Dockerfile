ARG SPARK_BASE_IMAGE=apache/spark:3.5.6-scala2.12-java17-python3-ubuntu
FROM ${SPARK_BASE_IMAGE}

ARG HADOOP_VERSION=3.3.4
ARG AWS_SDK_BUNDLE_VERSION=1.12.262

USER root

# Fail the image build if the Hadoop client bundled with Spark is not the
# exact version used by hadoop-aws. Mixing Hadoop patch versions is unsupported.
RUN set -eux; \
    test -f "/opt/spark/jars/hadoop-client-api-${HADOOP_VERSION}.jar"; \
    test -f "/opt/spark/jars/hadoop-client-runtime-${HADOOP_VERSION}.jar"

# Hadoop 3.3.4 hadoop-aws declares AWS SDK v1 bundle 1.12.262.
RUN python3 - <<'PY'
from pathlib import Path
from urllib.request import urlretrieve
import os

hadoop_version = os.environ["HADOOP_VERSION"]
aws_version = os.environ["AWS_SDK_BUNDLE_VERSION"]
artifacts = [
    (
        f"https://repo.maven.apache.org/maven2/org/apache/hadoop/hadoop-aws/{hadoop_version}/hadoop-aws-{hadoop_version}.jar",
        Path(f"/opt/spark/jars/hadoop-aws-{hadoop_version}.jar"),
    ),
    (
        f"https://repo.maven.apache.org/maven2/com/amazonaws/aws-java-sdk-bundle/{aws_version}/aws-java-sdk-bundle-{aws_version}.jar",
        Path(f"/opt/spark/jars/aws-java-sdk-bundle-{aws_version}.jar"),
    ),
]
for url, destination in artifacts:
    if not destination.exists():
        print(f"Downloading {destination.name}")
        urlretrieve(url, destination)
    if destination.stat().st_size < 1_000_000:
        raise RuntimeError(f"Unexpectedly small dependency: {destination}")
PY

RUN chown spark:spark \
    "/opt/spark/jars/hadoop-aws-${HADOOP_VERSION}.jar" \
    "/opt/spark/jars/aws-java-sdk-bundle-${AWS_SDK_BUNDLE_VERSION}.jar"

USER spark

ENV PYTHONUNBUFFERED=1 \
    PYSPARK_PYTHON=python3 \
    SPARK_HOME=/opt/spark
