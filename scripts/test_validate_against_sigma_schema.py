"""Proves the schema check can fail. A validator that accepts everything would leave the integration
suite green forever, so these tests take the known-good golden specs, break them in ways Sigma's
schema forbids, and require the validator to notice.

    pip install jsonschema
    python -m unittest scripts/test_validate_against_sigma_schema.py
"""
import copy
import gzip
import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import validate_against_sigma_schema as v  # noqa: E402

try:
    import jsonschema
except ImportError:  # CI installs it (ci/requirements-*.txt) and the integration script fails without it
    jsonschema = None

GOLDEN = Path(__file__).resolve().parent.parent / "integration_tests" / "expected"


@unittest.skipIf(jsonschema is None, "jsonschema is not installed")
class SchemaValidatorHasTeeth(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # Same normalisation as validate_against_sigma_schema.main().
        schema = json.loads(gzip.decompress(v.SCHEMA_PATH.read_bytes()).decode().replace('"oneOf"', '"anyOf"'))
        cls.validator = jsonschema.Draft202012Validator(schema)
        cls.specs = {p.stem: json.loads(p.read_text()) for p in sorted(GOLDEN.glob("*.json"))}

    def errors(self, spec):
        return list(self.validator.iter_errors(spec))

    def dashboard(self):
        return copy.deepcopy(self.specs["sigma_sales_dashboard"])

    def test_the_golden_specs_are_valid(self):
        self.assertGreaterEqual(len(self.specs), 3)
        for name, spec in self.specs.items():
            self.assertEqual(self.errors(spec), [], name)

    def test_missing_required_top_level_fields_are_rejected(self):
        # `contents` is deliberately not here: the published request body is a union that includes the
        # legacy nested-`spec` shape, so the schema alone accepts a body without it. The integration
        # script's export step asserts `contents` exists for that reason.
        for key in ("name", "folderId"):
            spec = self.dashboard()
            del spec[key]
            self.assertTrue(self.errors(spec), f"removing {key} should be rejected")

    def test_missing_required_contents_fields_are_rejected(self):
        for key in ("schemaVersion", "kind", "pages", "elements", "layout"):
            spec = self.dashboard()
            del spec["contents"][key]
            self.assertTrue(self.errors(spec), f"removing contents.{key} should be rejected")

    def test_an_unknown_element_kind_is_rejected(self):
        spec = self.dashboard()
        spec["contents"]["elements"][0]["kind"] = "hologram-chart"
        self.assertTrue(self.errors(spec))

    def test_a_wrong_type_is_rejected(self):
        spec = self.dashboard()
        spec["contents"]["pages"] = "not a list"
        self.assertTrue(self.errors(spec))

    def test_a_bad_enum_value_is_rejected(self):
        spec = self.dashboard()
        table = next(e for e in spec["contents"]["elements"] if e["kind"] == "table" and e.get("sort"))
        table["sort"][0]["direction"] = "sideways"
        self.assertTrue(self.errors(spec))

    def test_a_workbook_with_a_bad_source_kind_is_rejected(self):
        spec = self.dashboard()
        chart = next(e for e in spec["contents"]["elements"] if e["kind"] == "bar-chart")
        chart["source"]["kind"] = "warehouse-view"
        self.assertTrue(self.errors(spec))


class LoadSpecs(unittest.TestCase):
    def test_load_specs_ignores_models_without_a_workbook(self):
        import tempfile

        manifest = {"nodes": {
            "model.p.a": {"resource_type": "model", "name": "a", "config": {"meta": {"sigma_workbook": {"name": "A"}}}},
            "model.p.b": {"resource_type": "model", "name": "b", "config": {"meta": {}}},
            "seed.p.c": {"resource_type": "seed", "name": "c", "config": {"meta": {"sigma_workbook": {"name": "C"}}}},
        }}
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "manifest.json"
            path.write_text(json.dumps(manifest))
            self.assertEqual(v.load_specs(path), {"a": {"name": "A"}})


if __name__ == "__main__":
    unittest.main()
