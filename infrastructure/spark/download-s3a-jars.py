"""Download the pinned S3A runtime dependencies during the Spark image build."""

import os
from pathlib import Path
from urllib.request import urlretrieve

hadoop_version = os.environ["HADOOP_VERSION"]
aws_version = os.environ["AWS_SDK_BUNDLE_VERSION"]

artifacts = [
    (
        f"https://repo.maven.apache.org/maven2/org/apache/hadoop/hadoop-aws/{hadoop_version}/hadoop-aws-{hadoop_version}.jar",
        Path(f"/opt/spark/jars/hadoop-aws-{hadoop_version}.jar"),
        100_000,
    ),
    (
        f"https://repo.maven.apache.org/maven2/com/amazonaws/aws-java-sdk-bundle/{aws_version}/aws-java-sdk-bundle-{aws_version}.jar",
        Path(f"/opt/spark/jars/aws-java-sdk-bundle-{aws_version}.jar"),
        1_000_000,
    ),
    (
        "https://repo.maven.apache.org/maven2/org/wildfly/openssl/wildfly-openssl/1.0.7.Final/wildfly-openssl-1.0.7.Final.jar",
        Path("/opt/spark/jars/wildfly-openssl-1.0.7.Final.jar"),
        10_000,
    ),
]

for url, destination, minimum_size in artifacts:
    if not destination.exists():
        print(f"Downloading {destination.name}")
        urlretrieve(url, destination)
    if destination.stat().st_size < minimum_size:
        raise RuntimeError(f"Unexpectedly small dependency: {destination}")
