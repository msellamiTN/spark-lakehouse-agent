"""Unit tests for Lakehouse dataset contract validation."""

import copy
import json
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from validate_lakehouse_contracts import ContractError, validate_contract  # noqa: E402


class DatasetContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        contract_path = ROOT / "docs/contracts/datasets/retail-transactions.json"
        cls.valid_contract = json.loads(contract_path.read_text(encoding="utf-8"))

    def test_reference_contract_is_valid(self):
        validate_contract(copy.deepcopy(self.valid_contract))

    def test_rejects_source_path_outside_raw_zone(self):
        contract = copy.deepcopy(self.valid_contract)
        contract["source"]["path_template"] = "s3a://lakehouse/bronze/retail/transactions/"
        with self.assertRaisesRegex(ContractError, "source path"):
            validate_contract(contract)

    def test_rejects_target_path_zone_mismatch(self):
        contract = copy.deepcopy(self.valid_contract)
        contract["target"]["path_template"] = "s3a://lakehouse/silver/retail/transactions/"
        with self.assertRaisesRegex(ContractError, "target path"):
            validate_contract(contract)

    def test_rejects_duplicate_field_names(self):
        contract = copy.deepcopy(self.valid_contract)
        contract["fields"].append(copy.deepcopy(contract["fields"][0]))
        with self.assertRaisesRegex(ContractError, "field names must be unique"):
            validate_contract(contract)

    def test_rejects_nullable_primary_key(self):
        contract = copy.deepcopy(self.valid_contract)
        contract["fields"][0]["nullable"] = True
        with self.assertRaisesRegex(ContractError, "must be non-nullable"):
            validate_contract(contract)

    def test_rejects_undeclared_partition_column(self):
        contract = copy.deepcopy(self.valid_contract)
        contract["partition_by"] = ["unknown_partition"]
        with self.assertRaisesRegex(ContractError, "not declared"):
            validate_contract(contract)

    def test_rejects_unsupported_logical_type(self):
        contract = copy.deepcopy(self.valid_contract)
        contract["fields"][0]["type"] = "binary_blob"
        with self.assertRaisesRegex(ContractError, "unsupported"):
            validate_contract(contract)

    def test_rejects_non_semver_contract_version(self):
        contract = copy.deepcopy(self.valid_contract)
        contract["contract_version"] = "v1"
        with self.assertRaisesRegex(ContractError, "MAJOR.MINOR.PATCH"):
            validate_contract(contract)


if __name__ == "__main__":
    unittest.main()
