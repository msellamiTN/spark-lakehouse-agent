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
ENV HADOOP_VERSION=${HADOOP_VERSION} \
    AWS_SDK_BUNDLE_VERSION=${AWS_SDK_BUNDLE_VERSION}
COPY download-s3a-jars.py /tmp/download-s3a-jars.py
RUN python3 /tmp/download-s3a-jars.py \
    && chown spark:spark \
       "/opt/spark/jars/hadoop-aws-${HADOOP_VERSION}.jar" \
       "/opt/spark/jars/aws-java-sdk-bundle-${AWS_SDK_BUNDLE_VERSION}.jar" \
    && rm /tmp/download-s3a-jars.py

USER spark

ENV PYTHONUNBUFFERED=1 \
    PYSPARK_PYTHON=python3 \
    SPARK_HOME=/opt/spark
