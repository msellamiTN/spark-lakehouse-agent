"""Scoped MinIO MCP server for lakehouse object discovery and controlled text access."""

import json
import os
from datetime import timezone

import boto3
from botocore.config import Config
from mcp.server.fastmcp import FastMCP

mcp = FastMCP(
    "minio-lakehouse",
    instructions=(
        "Access only the configured MinIO bucket allowlist. List and inspect objects, "
        "read small text objects, and optionally write text outputs when write access "
        "is explicitly enabled. Do not expose or return credentials."
    ),
)

ENDPOINT = os.getenv("MINIO_ENDPOINT", "http://minio:9000")
ACCESS_KEY = os.getenv("MINIO_MCP_ACCESS_KEY") or os.getenv("MINIO_ROOT_USER", "")
SECRET_KEY = os.getenv("MINIO_MCP_SECRET_KEY") or os.getenv("MINIO_ROOT_PASSWORD", "")
REGION = os.getenv("MINIO_REGION", "us-east-1")
ALLOWED_BUCKETS = {
    value.strip() for value in os.getenv("MINIO_MCP_ALLOWED_BUCKETS", "lakehouse").split(",")
    if value.strip()
}
ALLOWED_WRITE_PREFIXES = tuple(
    value.strip() for value in os.getenv("MINIO_MCP_WRITE_PREFIXES", "agent-outputs/").split(",")
    if value.strip()
)
ALLOW_WRITES = os.getenv("MINIO_MCP_ALLOW_WRITES", "false").lower() == "true"
MAX_READ_BYTES = int(os.getenv("MINIO_MCP_MAX_READ_BYTES", "1048576"))
MAX_WRITE_BYTES = int(os.getenv("MINIO_MCP_MAX_WRITE_BYTES", "1048576"))


def _client():
    if not ACCESS_KEY or not SECRET_KEY:
        raise RuntimeError("MinIO MCP credentials are not configured.")
    return boto3.client(
        "s3",
        endpoint_url=ENDPOINT,
        aws_access_key_id=ACCESS_KEY,
        aws_secret_access_key=SECRET_KEY,
        region_name=REGION,
        config=Config(
            signature_version="s3v4",
            connect_timeout=5,
            read_timeout=20,
            retries={"max_attempts": 2},
            s3={"addressing_style": "path"},
        ),
    )


def _bucket(bucket: str) -> str:
    if bucket not in ALLOWED_BUCKETS:
        raise ValueError("Bucket is not in MINIO_MCP_ALLOWED_BUCKETS.")
    return bucket


def _safe_prefix(prefix: str) -> str:
    if prefix.startswith("/") or ".." in prefix.split("/"):
        raise ValueError("Absolute paths and parent-directory segments are not allowed.")
    return prefix


def _object_key(key: str) -> str:
    if not key or key.startswith("/") or ".." in key.split("/"):
        raise ValueError("Object key must be a non-empty relative key without parent-directory segments.")
    return key


def _write_key(key: str) -> str:
    if not ALLOW_WRITES:
        raise PermissionError("MinIO MCP writes are disabled. Set MINIO_MCP_ALLOW_WRITES=true to enable them.")
    safe_key = _object_key(key)
    if not any(safe_key.startswith(prefix) for prefix in ALLOWED_WRITE_PREFIXES):
        raise PermissionError("Writes are restricted to MINIO_MCP_WRITE_PREFIXES.")
    return safe_key


@mcp.tool()
def list_buckets() -> str:
    """Check availability of configured buckets without requiring account-wide bucket enumeration."""
    client = _client()
    available = []
    for name in sorted(ALLOWED_BUCKETS):
        try:
            response = client.head_bucket(Bucket=name)
            available.append({"name": name, "accessible": True, "http_status": response.get("ResponseMetadata", {}).get("HTTPStatusCode")})
        except Exception as exc:
            available.append({"name": name, "accessible": False, "error": type(exc).__name__})
    return json.dumps({"configured_allowlist": sorted(ALLOWED_BUCKETS), "buckets": available}, indent=2)


@mcp.tool()
def list_objects(bucket: str, prefix: str = "", max_keys: int = 100, continuation_token: str = "") -> str:
    """List objects under an allowed prefix. Use the returned continuation token to fetch the next page."""
    name = _bucket(bucket)
    safe_prefix = _safe_prefix(prefix)
    if max_keys < 1 or max_keys > 500:
        raise ValueError("max_keys must be between 1 and 500.")
    request = {"Bucket": name, "Prefix": safe_prefix, "MaxKeys": max_keys}
    if continuation_token:
        request["ContinuationToken"] = continuation_token
    response = _client().list_objects_v2(**request)
    objects = [
        {
            "key": item["Key"],
            "size_bytes": item["Size"],
            "last_modified": item["LastModified"].astimezone(timezone.utc).isoformat(),
            "etag": item["ETag"].strip('"'),
        }
        for item in response.get("Contents", [])
    ]
    return json.dumps(
        {"bucket": name, "prefix": safe_prefix, "objects": objects,
         "is_truncated": response.get("IsTruncated", False),
         "next_continuation_token": response.get("NextContinuationToken")},
        indent=2,
    )


@mcp.tool()
def get_object_metadata(bucket: str, key: str) -> str:
    """Return metadata for one object without downloading its contents."""
    name = _bucket(bucket)
    object_key = _object_key(key)
    response = _client().head_object(Bucket=name, Key=object_key)
    return json.dumps(
        {
            "bucket": name,
            "key": object_key,
            "size_bytes": response.get("ContentLength"),
            "content_type": response.get("ContentType"),
            "etag": response.get("ETag", "").strip('"'),
            "last_modified": response.get("LastModified").astimezone(timezone.utc).isoformat()
            if response.get("LastModified") else None,
            "metadata": response.get("Metadata", {}),
        },
        indent=2,
    )


@mcp.tool()
def read_text_object(bucket: str, key: str) -> str:
    """Read a small UTF-8 text, JSON, CSV, YAML or Markdown object (maximum configured byte size)."""
    name = _bucket(bucket)
    object_key = _object_key(key)
    response = _client().get_object(Bucket=name, Key=object_key)
    content_type = response.get("ContentType", "").lower()
    allowed_suffixes = (".txt", ".md", ".csv", ".json", ".yaml", ".yml", ".log")
    if not (content_type.startswith("text/") or object_key.lower().endswith(allowed_suffixes)
            or "json" in content_type):
        response["Body"].close()
        raise ValueError("Only text, JSON, CSV, YAML and Markdown objects can be read with this tool.")
    body = response["Body"]
    try:
        data = body.read(MAX_READ_BYTES + 1)
    finally:
        body.close()
    if len(data) > MAX_READ_BYTES:
        raise ValueError(f"Object exceeds the {MAX_READ_BYTES}-byte read limit.")
    return data.decode("utf-8-sig")


@mcp.tool()
def write_text_object(bucket: str, key: str, content: str, content_type: str = "text/plain; charset=utf-8") -> str:
    """Write a small text artifact under an approved prefix. Disabled unless explicitly enabled."""
    name = _bucket(bucket)
    object_key = _write_key(key)
    payload = content.encode("utf-8")
    if len(payload) > MAX_WRITE_BYTES:
        raise ValueError(f"Content exceeds the {MAX_WRITE_BYTES}-byte write limit.")
    if not content_type.startswith(("text/", "application/json")):
        raise ValueError("Only text/* and application/json content types are accepted.")
    response = _client().put_object(
        Bucket=name,
        Key=object_key,
        Body=payload,
        ContentType=content_type,
    )
    return json.dumps(
        {"status": "written", "bucket": name, "key": object_key,
         "etag": response.get("ETag", "").strip('"'), "size_bytes": len(payload)},
        indent=2,
    )


if __name__ == "__main__":
    mcp.run(
        transport="streamable-http",
        host=os.getenv("MCP_HOST", "0.0.0.0"),
        port=int(os.getenv("MCP_PORT", "8001")),
        stateless_http=True,
    )
