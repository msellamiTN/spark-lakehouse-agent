# Download and verify the pinned MinIO Client inside the Docker build stage.
# The runtime image contains only the mc executable and CA certificates.
FROM alpine:3.22 AS mc-fetch

ARG MC_RELEASE=RELEASE.2025-08-13T08-35-41Z
ARG MC_SHA256=01f866e9c5f9b87c2b09116fa5d7c06695b106242d829a8bb32990c00312e891

RUN set -eux; \
    apk add --no-cache ca-certificates curl; \
    curl -fL --retry 3 --retry-all-errors \
      -o /tmp/mc \
      "https://github.com/minio/mc/releases/download/${MC_RELEASE}/mc.linux-amd64.${MC_RELEASE}"; \
    echo "${MC_SHA256}  /tmp/mc" | sha256sum -c -; \
    mkdir -p /out/usr/bin /out/etc/ssl/certs; \
    install -m 0755 /tmp/mc /out/usr/bin/mc; \
    cp /etc/ssl/certs/ca-certificates.crt /out/etc/ssl/certs/ca-certificates.crt

FROM scratch

LABEL org.opencontainers.image.title="Data2AI MinIO Client" \
      org.opencontainers.image.version="RELEASE.2025-08-13T08-35-41Z" \
      org.opencontainers.image.description="Pinned, checksum-verified MinIO administration client"

COPY --from=mc-fetch /out/usr/bin/mc /usr/bin/mc
COPY --from=mc-fetch /out/etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt

ENTRYPOINT ["/usr/bin/mc"]
