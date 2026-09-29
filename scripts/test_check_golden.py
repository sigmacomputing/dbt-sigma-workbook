"""Tests for check_golden.py.

    python -m unittest scripts/test_check_golden.py
"""
import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import check_golden as cg  # noqa: E402


class GoldenTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.actual = Path(self._tmp.name) / "actual"
        self.expected = Path(self._tmp.name) / "expected"
        self.actual.mkdir()
        self.expected.mkdir()

    def write(self, directory, name, value):
        (directory / f"{name}.json").write_text(json.dumps(value, indent=2) + "\n")

    def test_identical_specs_match_regardless_of_key_order_and_whitespace(self):
        self.write(self.actual, "a", {"x": 1, "y": [1, 2]})
        (self.expected / "a.json").write_text('{"y":[1,2],   "x":1}')
        self.assertEqual(cg.compare(self.actual, self.expected), [])

    def test_a_changed_value_is_reported_with_a_diff(self):
        self.write(self.actual, "a", {"name": "new"})
        self.write(self.expected, "a", {"name": "old"})
        (problem,) = cg.compare(self.actual, self.expected)
        self.assertIn("a.json: differs", problem)
        self.assertIn('-  "name": "old"', problem)
        self.assertIn('+  "name": "new"', problem)

    def test_list_order_matters(self):
        self.write(self.actual, "a", {"pages": [1, 2]})
        self.write(self.expected, "a", {"pages": [2, 1]})
        self.assertEqual(len(cg.compare(self.actual, self.expected)), 1)

    def test_connection_ids_are_not_part_of_the_snapshot(self):
        source = lambda cid: {"elements": [{"source": {"kind": "warehouse-table", "connectionId": cid, "path": ["a", "b", "c"]}}]}
        self.write(self.actual, "a", source("real-connection"))
        self.write(self.expected, "a", source("some-other-connection"))
        self.assertEqual(cg.compare(self.actual, self.expected), [])

    def test_other_environment_values_are_still_compared(self):
        self.write(self.actual, "a", {"folderId": "folder-1", "source": {"connectionId": "x"}})
        self.write(self.expected, "a", {"folderId": "folder-2", "source": {"connectionId": "y"}})
        (problem,) = cg.compare(self.actual, self.expected)
        self.assertIn("folder-1", problem)
        self.assertNotIn("connectionId", "".join(line for line in problem.splitlines() if line[:1] in "+-"))

    def test_update_stores_the_placeholder_not_the_real_connection_id(self):
        self.write(self.actual, "a", {"source": {"connectionId": "real-connection"}, "list": [{"connectionId": "real-connection"}]})
        cg.update(self.actual, self.expected)
        written = (self.expected / "a.json").read_text()
        self.assertNotIn("real-connection", written)
        self.assertEqual(written.count("<connectionId>"), 2)

    def test_new_and_removed_workbooks_are_reported(self):
        self.write(self.actual, "new", {})
        self.write(self.expected, "gone", {})
        problems = " ".join(cg.compare(self.actual, self.expected))
        self.assertIn("new.json: compiled but has no golden file", problems)
        self.assertIn("gone.json: golden file exists but the workbook was not compiled", problems)

    def test_missing_expected_directory_is_a_failure_not_a_pass(self):
        self.write(self.actual, "a", {})
        self.assertEqual(len(cg.compare(self.actual, self.expected / "nope")), 1)

    def test_long_diffs_are_truncated(self):
        self.write(self.actual, "a", {"items": list(range(500))})
        self.write(self.expected, "a", {"items": []})
        (problem,) = cg.compare(self.actual, self.expected)
        self.assertIn("more diff lines", problem)
        self.assertLess(len(problem.splitlines()), cg.MAX_DIFF_LINES + 5)

    def test_update_replaces_stale_files(self):
        self.write(self.actual, "a", {"v": 2})
        self.write(self.expected, "a", {"v": 1})
        self.write(self.expected, "stale", {})
        self.assertEqual(cg.update(self.actual, self.expected), ["a.json"])
        self.assertEqual(cg.compare(self.actual, self.expected), [])
        self.assertFalse((self.expected / "stale.json").exists())

    def test_main_exit_codes(self):
        self.write(self.actual, "a", {"v": 1})
        self.write(self.expected, "a", {"v": 1})
        args = ["--actual", str(self.actual), "--expected", str(self.expected)]
        self.assertEqual(cg.main(args), 0)
        self.write(self.expected, "a", {"v": 2})
        self.assertEqual(cg.main(args), 1)
        self.assertEqual(cg.main(args + ["--update"]), 0)
        self.assertEqual(cg.main(args), 0)
        self.assertEqual(cg.main(["--actual", str(self.actual / "empty"), "--expected", str(self.expected)]), 2)


class CommittedGoldenFiles(unittest.TestCase):
    """The committed snapshots themselves must be sane, so `--update` can't quietly commit garbage."""

    def test_golden_files_exist_and_are_complete_create_requests(self):
        files = sorted(cg.DEFAULT_EXPECTED.glob("*.json"))
        self.assertGreaterEqual(len(files), 3)
        for path in files:
            spec = json.loads(path.read_text())
            contents = spec["contents"]
            self.assertTrue(spec["name"] and spec["folderId"], path.name)
            self.assertTrue(contents["pages"] and contents["elements"] and contents["layout"], path.name)
            self.assertNotIn("/Users/", path.read_text(), f"{path.name} leaks a local path")

    def test_golden_files_hold_no_real_connection_id(self):
        for path in sorted(cg.DEFAULT_EXPECTED.glob("*.json")):
            found = set()

            def walk(node):
                if isinstance(node, dict):
                    for key, value in node.items():
                        if key == "connectionId":
                            found.add(value)
                        walk(value)
                elif isinstance(node, list):
                    for item in node:
                        walk(item)

            walk(json.loads(path.read_text()))
            self.assertLessEqual(found, {"<connectionId>"}, f"{path.name} holds a real connection id: {found}")


if __name__ == "__main__":
    unittest.main()
