ARG SPARK_IMAGE=apache/spark:3.5.6-scala2.12-java17-python3-ubuntu
FROM ${SPARK_IMAGE}

USER root
RUN python3 -m pip install --no-cache-dir --upgrade pip \
    && python3 -m pip install --no-cache-dir \
       jupyterlab==4.4.5 \
       ipykernel==6.30.1 \
       pandas==2.2.3 \
       pyarrow==20.0.0 \
       matplotlib==3.10.3 \
       plotly==6.2.0 \
       duckdb==1.3.2 \
       boto3==1.39.11 \
       requests==2.32.4 \
       python-dotenv==1.1.1

RUN mkdir -p /workspace/notebooks /workspace/retail /lakehouse \
    && chown -R spark:spark /workspace /lakehouse /home/spark

USER spark
WORKDIR /workspace
EXPOSE 8888
