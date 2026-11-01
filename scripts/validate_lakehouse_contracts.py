#!/usr/bin/env python3
"""Validate checked-in Lakehouse dataset contracts using only the stdlib."""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
CONTRACT_DIR = ROOT / "docs" / "contracts" / "datasets"
SCHEMA_FILE = ROOT / "docs" / "contracts" / "schema" / "dataset-contract.schema.json"
IDENTIFIER = re.compile(r"^[a-z][a-z0-9_]*$")
SEMVER = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")
FIELD_TYPES = {
    "string", "int", "long", "decimal", "double",
    "boolean", "date", "timestamp",
}
ZONES = {"bronze", "silver", "gold"}


class ContractError(ValueError):
    """Raised when a dataset contract violates repository rules."""


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise ContractError(message)


def validate_contract(contract: dict[str, Any]) -> None:
    required = {
        "contract_version", "dataset_id", "domain", "name", "owner",
        "description", "source", "target", "primary_key", "partition_by", "fields",
    }
    _require(isinstance(contract, dict), "contract root must be an object")
    missing = required - contract.keys()
    _require(not missing, f"missing top-level properties: {', '.join(sorted(missing))}")

    domain = contract["domain"]
    name = contract["name"]
    _require(isinstance(domain, str) and IDENTIFIER.fullmatch(domain), "domain must be lowercase snake_case")
    _require(isinstance(name, str) and IDENTIFIER.fullmatch(name), "name must be lowercase snake_case")
    _require(contract["dataset_id"] == f"{domain}.{name}", "dataset_id must equal '<domain>.<name>'")
    _require(isinstance(contract["contract_version"], str) and SEMVER.fullmatch(contract["contract_version"]), "contract_version must use MAJOR.MINOR.PATCH")
    _require(isinstance(contract["owner"], str) and len(contract["owner"].strip()) >= 2, "owner must be a non-empty team or role")
    _require(isinstance(contract["description"], str) and len(contract["description"].strip()) >= 10, "description must contain at least 10 characters")

    source = contract["source"]
    _require(isinstance(source, dict), "source must be an object")
    _require(source.get("zone") == "raw", "source.zone must be 'raw'")
    _require(source.get("format") in {"csv", "json", "parquet"}, "source.format must be csv, json or parquet")
    source_path = source.get("path_template")
    _require(isinstance(source_path, str) and source_path.startswith(f"s3a://lakehouse/raw/{domain}/{name}/"), "source path must be under matching raw/<domain>/<dataset>")

    target = contract["target"]
    _require(isinstance(target, dict), "target must be an object")
    zone = target.get("zone")
    _require(zone in ZONES, "target.zone must be bronze, silver or gold")
    _require(target.get("format") == "parquet", "curated target format must be parquet")
    target_path = target.get("path_template")
    _require(isinstance(target_path, str) and target_path.startswith(f"s3a://lakehouse/{zone}/{domain}/{name}/"), "target path must match target zone/domain/dataset")

    fields = contract["fields"]
    _require(isinstance(fields, list) and fields, "fields must be a non-empty array")
    field_names: list[str] = []
    nullable_by_name: dict[str, bool] = {}
    for index, field in enumerate(fields):
        _require(isinstance(field, dict), f"fields[{index}] must be an object")
        field_name = field.get("name")
        _require(isinstance(field_name, str) and IDENTIFIER.fullmatch(field_name), f"fields[{index}].name must be lowercase snake_case")
        _require(field.get("type") in FIELD_TYPES, f"fields[{index}].type is unsupported")
        _require(isinstance(field.get("nullable"), bool), f"fields[{index}].nullable must be boolean")
        _require(isinstance(field.get("description"), str) and len(field["description"].strip()) >= 3, f"fields[{index}].description is too short")
        field_names.append(field_name)
        nullable_by_name[field_name] = field["nullable"]
    _require(len(field_names) == len(set(field_names)), "field names must be unique")

    primary_key = contract["primary_key"]
    _require(isinstance(primary_key, list) and primary_key, "primary_key must be a non-empty array")
    _require(len(primary_key) == len(set(primary_key)), "primary_key entries must be unique")
    for key in primary_key:
        _require(key in nullable_by_name, f"primary key field '{key}' is not declared")
        _require(nullable_by_name[key] is False, f"primary key field '{key}' must be non-nullable")

    partitions = contract["partition_by"]
    _require(isinstance(partitions, list), "partition_by must be an array")
    _require(len(partitions) == len(set(partitions)), "partition_by entries must be unique")
    for partition in partitions:
        _require(partition in nullable_by_name, f"partition field '{partition}' is not declared")

    rules = contract.get("quality_rules", [])
    _require(isinstance(rules, list), "quality_rules must be an array")
    rule_ids: list[str] = []
    for index, rule in enumerate(rules):
        _require(isinstance(rule, dict), f"quality_rules[{index}] must be an object")
        rule_id = rule.get("rule_id")
        _require(isinstance(rule_id, str) and IDENTIFIER.fullmatch(rule_id), f"quality_rules[{index}].rule_id is invalid")
        _require(isinstance(rule.get("description"), str) and len(rule["description"].strip()) >= 5, f"quality_rules[{index}].description is too short")
        _require(rule.get("severity") in {"error", "warning"}, f"quality_rules[{index}].severity must be error or warning")
        rule_ids.append(rule_id)
    _require(len(rule_ids) == len(set(rule_ids)), "quality rule IDs must be unique")


def validate_repository() -> list[str]:
    if not SCHEMA_FILE.is_file():
        raise ContractError(f"JSON Schema not found: {SCHEMA_FILE.relative_to(ROOT)}")
    with SCHEMA_FILE.open(encoding="utf-8") as handle:
        schema = json.load(handle)
    _require(schema.get("$schema") == "https://json-schema.org/draft/2020-12/schema", "schema must declare JSON Schema Draft 2020-12")
    _require(schema.get("type") == "object", "dataset contract schema root must be an object")

    contract_files = sorted(CONTRACT_DIR.glob("*.json"))
    _require(bool(contract_files), f"no dataset contracts found in {CONTRACT_DIR.relative_to(ROOT)}")
    validated: list[str] = []
    for path in contract_files:
        with path.open(encoding="utf-8") as handle:
            contract = json.load(handle)
        validate_contract(contract)
        validated.append(path.relative_to(ROOT).as_posix())
    return validated


def main() -> int:
    try:
        files = validate_repository()
    except (ContractError, json.JSONDecodeError, OSError) as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        return 1
    for filename in files:
        print(f"PASS: {filename}")
    print(f"Validated {len(files)} Lakehouse dataset contract(s).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
