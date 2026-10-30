import os
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import minio_server
import spark_server


class SparkGuardrailTests(unittest.TestCase):
    def test_select_is_accepted(self):
        self.assertEqual(spark_server._validate_select("SELECT 1"), "SELECT 1")

    def test_non_select_statement_is_rejected(self):
        with self.assertRaises(ValueError):
            spark_server._validate_select("DROP TABLE customers")

    def test_multiple_statements_are_rejected(self):
        with self.assertRaises(ValueError):
            spark_server._validate_select("SELECT 1; DROP TABLE customers")

    def test_sql_comments_are_rejected(self):
        with self.assertRaises(ValueError):
            spark_server._validate_select("SELECT 1 -- comment")

    def test_dangerous_function_is_rejected(self):
        with self.assertRaises(ValueError):
            spark_server._validate_select("SELECT java_method('x', 'y')")

    def test_identifier_validation(self):
        self.assertEqual(spark_server._identifier("sales_2026", "table"), "sales_2026")
        with self.assertRaises(ValueError):
            spark_server._identifier("sales; DROP TABLE x", "table")


class MinIOGuardrailTests(unittest.TestCase):
    def test_bucket_allowlist(self):
        with patch.object(minio_server, "ALLOWED_BUCKETS", {"lakehouse"}):
            self.assertEqual(minio_server._bucket("lakehouse"), "lakehouse")
            with self.assertRaises(ValueError):
                minio_server._bucket("private")

    def test_prefix_traversal_is_rejected(self):
        with self.assertRaises(ValueError):
            minio_server._safe_prefix("../private/")

    def test_object_key_traversal_is_rejected(self):
        with self.assertRaises(ValueError):
            minio_server._object_key("bronze/../../secrets.txt")

    def test_writes_are_disabled_by_default(self):
        with patch.object(minio_server, "ALLOW_WRITES", False):
            with self.assertRaises(PermissionError):
                minio_server._write_key("agent-outputs/result.json")

    def test_write_prefix_is_enforced(self):
        with patch.object(minio_server, "ALLOW_WRITES", True), patch.object(
            minio_server, "ALLOWED_WRITE_PREFIXES", ("agent-outputs/",)
        ):
            self.assertEqual(
                minio_server._write_key("agent-outputs/result.json"),
                "agent-outputs/result.json",
            )
            with self.assertRaises(PermissionError):
                minio_server._write_key("bronze/result.json")


if __name__ == "__main__":
    unittest.main()
