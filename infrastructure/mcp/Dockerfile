ARG SPARK_IMAGE=apache/spark:3.5.6-scala2.12-java17-python3-ubuntu
FROM \${SPARK_IMAGE}

USER root
WORKDIR /app

# Keep this server on the maintained MCP Python SDK v1 API line.
RUN python3 -m pip install --no-cache-dir \
    "mcp>=1.28,<2" \
    "boto3==1.39.11"

COPY spark_server.py /app/spark_server.py
COPY minio_server.py /app/minio_server.py

USER spark

ENV PYTHONUNBUFFERED=1 \
    PYSPARK_PYTHON=python3 \
    SPARK_HOME=/opt/spark

EXPOSE 8000 8001
