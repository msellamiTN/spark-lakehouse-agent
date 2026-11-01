# Lakehouse dataset contracts

This directory contains versioned, machine-readable dataset contracts.

- schema/dataset-contract.schema.json: JSON Schema Draft 2020-12 for the contract structure.
- datasets/retail-transactions.json: initial example used by the Phase 2.1 foundation.

## Validate

From the repository root:

~~~bash
python3 scripts/validate_lakehouse_contracts.py
python3 -m unittest discover -s tests -v
~~~

The local semantic validator uses only the Python standard library. GitHub Actions additionally installs jsonschema, checks the Draft 2020-12 schema itself, and validates every dataset contract against it.

## Contract rules

- Contract versions use semantic version syntax MAJOR.MINOR.PATCH.
- Dataset IDs are stable domain.dataset identifiers.
- Source paths must be under s3a://lakehouse/raw/.
- Curated targets must be under the declared Bronze, Silver or Gold zone and use Parquet.
- Field names, primary keys and partition columns use lowercase snake_case.
- Primary-key and partition columns must be declared in fields.
- Primary-key fields must be non-nullable.
- Contract files must never contain credentials, tokens or real personal data.
