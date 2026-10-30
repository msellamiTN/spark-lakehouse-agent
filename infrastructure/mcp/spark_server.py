"""Read-only Spark MCP server for the local Spark Standalone cluster."""

import json
import os
import re
from datetime import date, datetime
from decimal import Decimal
from functools import lru_cache
from typing import Any

from mcp.server.fastmcp import FastMCP
from pyspark.sql import SparkSession

mcp = FastMCP(
    "spark-lakehouse",
    instructions=(
        "Read-only access to the local Spark lakehouse. Discover databases and tables, "
        "inspect schemas, and run bounded SELECT queries. Do not assume MinIO is "
        "integrated with Spark: S3A is a later-phase capability."
    ),
    host=os.getenv("MCP_HOST", "0.0.0.0"),
    port=int(os.getenv("MCP_PORT", "8000")),
    stateless_http=True,
)

MASTER = os.getenv("SPARK_MASTER", "spark://spark-master:7077")
APP_NAME = os.getenv("SPARK_MCP_APP_NAME", "spark-lakehouse-mcp")
DEFAULT_MAX_ROWS = int(os.getenv("SPARK_MCP_MAX_ROWS", "100"))
HARD_MAX_ROWS = int(os.getenv("SPARK_MCP_HARD_MAX_ROWS", "500"))


@lru_cache(maxsize=1)
def _spark() -> SparkSession:
    return (
        SparkSession.builder
        .appName(APP_NAME)
        .master(MASTER)
        .config("spark.sql.session.timeZone", "UTC")
        .config("spark.driver.host", os.getenv("SPARK_DRIVER_HOST", "spark-mcp"))
        .config("spark.driver.bindAddress", "0.0.0.0")
        .getOrCreate()
    )


def _json_value(value: Any) -> Any:
    if isinstance(value, (datetime, date)):
        return value.isoformat()
    if isinstance(value, Decimal):
        return str(value)
    return value


def _identifier(value: str, label: str) -> str:
    if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", value or ""):
        raise ValueError(f"Invalid {label}. Use letters, digits and underscores; do not include SQL syntax.")
    return value


def _validate_select(sql: str) -> str:
    query = (sql or "").strip()
    if not query:
        raise ValueError("SQL query cannot be empty.")
    if len(query) > 20_000:
        raise ValueError("SQL query exceeds the 20,000 character limit.")
    if ";" in query or "--" in query or "/*" in query or "*/" in query:
        raise ValueError("Only a single statement is allowed; SQL comments and semicolons are not accepted.")
    if not re.match(r"(?is)^SELECT\b", query):
        raise ValueError("Only SELECT statements are allowed. Use catalog tools for metadata discovery.")
    denied = re.compile(
        r"(?i)\b(INSERT|UPDATE|DELETE|MERGE|DROP|ALTER|CREATE|TRUNCATE|"
        r"GRANT|REVOKE|SET|RESET|USE|CACHE|UNCACHE|REFRESH|LOAD|ADD|REMOVE|"
        r"CALL|EXECUTE|EXPORT|IMPORT|JAVA_METHOD|REFLECT)\b"
    )
    if denied.search(query):
        raise ValueError("The query contains a prohibited command or function.")
    return query


@mcp.tool()
def get_spark_session_info() -> str:
    """Return Spark version, master endpoint, application ID and default database."""
    spark = _spark()
    return json.dumps(
        {
            "spark_version": spark.version,
            "master": spark.sparkContext.master,
            "application_id": spark.sparkContext.applicationId,
            "application_name": spark.sparkContext.appName,
            "default_database": spark.catalog.currentDatabase(),
            "access_mode": "read_only",
        },
        indent=2,
    )


@mcp.tool()
def list_databases() -> str:
    """List databases visible to the MCP Spark session."""
    rows = [{"name": item.name, "description": item.description, "location": item.locationUri}
            for item in _spark().catalog.listDatabases()]
    return json.dumps(rows, indent=2)


@mcp.tool()
def list_tables(database: str = "default") -> str:
    """List tables and views in a database. The database must be a simple identifier."""
    db = _identifier(database, "database name")
    rows = [{"name": item.name, "database": item.database, "table_type": item.tableType,
             "is_temporary": item.isTemporary}
            for item in _spark().catalog.listTables(db)]
    return json.dumps(rows, indent=2)


@mcp.tool()
def describe_table(database: str, table: str) -> str:
    """Return column names, data types and comments for a table."""
    db = _identifier(database, "database name")
    tbl = _identifier(table, "table name")
    rows = _spark().sql(f"DESCRIBE TABLE {db}.{tbl}").collect()
    return json.dumps([row.asDict(recursive=True) for row in rows], indent=2, default=_json_value)


@mcp.tool()
def run_readonly_query(sql: str, max_rows: int = DEFAULT_MAX_ROWS) -> str:
    """Execute one bounded SELECT query. DDL, DML, multiple statements and SQL comments are rejected."""
    if max_rows < 1 or max_rows > HARD_MAX_ROWS:
        raise ValueError(f"max_rows must be between 1 and {HARD_MAX_ROWS}.")
    query = _validate_select(sql)
    rows = _spark().sql(query).limit(max_rows).collect()
    result = {
        "row_count_returned": len(rows),
        "max_rows": max_rows,
        "truncated_possible": len(rows) == max_rows,
        "columns": rows[0].__fields__ if rows else [],
        "rows": [row.asDict(recursive=True) for row in rows],
    }
    return json.dumps(result, indent=2, default=_json_value)


if __name__ == "__main__":
    mcp.run(transport="streamable-http")
