ARG SPARK_IMAGE=apache/spark:3.5.6-scala2.12-java17-python3-ubuntu
FROM ${SPARK_IMAGE}

USER root
WORKDIR /app

COPY requirements.txt /app/requirements.txt
# Keep this server on the maintained MCP Python SDK v1 API line.
RUN python3 -m pip install --no-cache-dir -r /app/requirements.txt

COPY spark_server.py /app/spark_server.py
COPY minio_server.py /app/minio_server.py
COPY tests /app/tests

USER spark

# The Spark distribution ships PySpark and Py4J as ZIP libraries; expose both
# to Python instead of installing a second, potentially mismatched PySpark package.
ENV PYTHONUNBUFFERED=1 \
    PYSPARK_PYTHON=python3 \
    SPARK_HOME=/opt/spark \
    PYTHONPATH=/opt/spark/python/lib/pyspark.zip:/opt/spark/python/lib/py4j-0.10.9.7-src.zip

EXPOSE 8000 8001
