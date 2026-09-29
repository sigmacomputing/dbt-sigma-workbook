#!/usr/bin/env python3
"""Validate compiled workbook specs against Sigma's published request schema.

`integration_tests/schema/create_workbook_request.schema.json.gz` is the request body of
`POST /v2/workbooks` extracted from Sigma's public OpenAPI document
(https://assets.sigmacomputing.com/openapi/public-rest-api/sigma-computing-public-rest-api.json), with
$refs preserved and prose stripped. Validating against it catches a misspelled field, a wrong enum
value or a missing required property without needing a Sigma account.

    pip install jsonschema
    python scripts/validate_against_sigma_schema.py --manifest integration_tests/target/manifest.json

What this catches: missing required properties, wrong types, wrong enum values, unknown element kinds.
What it does not: an unknown extra property (Sigma's schema allows them), or a formula that is not valid
in the target data source - only Sigma itself can check that (`export_workbooks.py --push --dry-run`).

Refresh the schema from the live OpenAPI with `--refresh` (needs network) after Sigma changes the API.
"""
from __future__ import annotations

import argparse
import gzip
import json
import sys
import urllib.request
from pathlib import Path

OPENAPI_URL = "https://assets.sigmacomputing.com/openapi/public-rest-api/sigma-computing-public-rest-api.json"
SCHEMA_PATH = Path(__file__).resolve().parent.parent / "integration_tests" / "schema" / "create_workbook_request.schema.json.gz"
DROPPED_KEYS = {"description", "title", "example", "examples"}


def extract_schema(openapi: dict) -> dict:
    """POST /v2/workbooks request body as a self-contained JSON Schema."""
    body = openapi["paths"]["/v2/workbooks"]["post"]["requestBody"]["content"]["application/json"]["schema"]
    defs: dict[str, object] = {}

    def walk(node):
        if isinstance(node, dict):
            if "$ref" in node:
                name = node["$ref"].split("/")[-1]
                if name not in defs:
                    defs[name] = None  # placeholder guards against reference cycles
                    defs[name] = walk(openapi["components"]["schemas"][name])
                return {"$ref": "#/$defs/" + name}
            return {k: walk(v) for k, v in node.items() if k not in DROPPED_KEYS}
        if isinstance(node, list):
            return [walk(x) for x in node]
        return node

    schema = walk(body)
    schema["$schema"] = "https://json-schema.org/draft/2020-12/schema"
    schema["$defs"] = defs
    return schema


def load_specs(manifest_path: Path) -> dict[str, dict]:
    manifest = json.loads(manifest_path.read_text())
    specs = {}
    for node in manifest["nodes"].values():
        spec = ((node.get("config") or {}).get("meta") or {}).get("sigma_workbook")
        if node.get("resource_type") == "model" and spec is not None:
            specs[node["name"]] = spec
    return specs


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--manifest", default="integration_tests/target/manifest.json")
    parser.add_argument("--refresh", action="store_true", help="re-download the OpenAPI document and rewrite the schema file")
    args = parser.parse_args()

    if args.refresh:
        with urllib.request.urlopen(OPENAPI_URL) as response:
            schema = extract_schema(json.load(response))
        SCHEMA_PATH.write_bytes(gzip.compress(json.dumps(schema, separators=(",", ":"), sort_keys=True).encode(), 9))
        print(f"refreshed {SCHEMA_PATH}")
        return 0

    try:
        import jsonschema
    except ImportError:
        print("error: pip install jsonschema", file=sys.stderr)
        return 2

    # Sigma's schema spells "one of these string enums, or any string" as a `oneOf` whose branches
    # overlap (e.g. theme.name: "Light" matches both), which `oneOf` rejects as ambiguous. `anyOf` is
    # the intended reading.
    schema = json.loads(gzip.decompress(SCHEMA_PATH.read_bytes()).decode().replace('"oneOf"', '"anyOf"'))
    validator = jsonschema.Draft202012Validator(schema)
    specs = load_specs(Path(args.manifest))
    if not specs:
        print("error: no workbook specs found in the manifest", file=sys.stderr)
        return 2

    failed = False
    for name, spec in specs.items():
        body = {k: v for k, v in spec.items() if k != "workbookId"}
        errors = sorted(validator.iter_errors(body), key=lambda e: list(e.absolute_path))
        if errors:
            failed = True
            print(f"FAIL {name}: {len(errors)} schema violation(s)")
            for error in errors[:15]:
                path = "/".join(str(p) for p in error.absolute_path) or "<root>"
                print(f"   at {path}: {error.message[:300]}")
        else:
            print(f"ok   {name} conforms to Sigma's POST /v2/workbooks request schema")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
