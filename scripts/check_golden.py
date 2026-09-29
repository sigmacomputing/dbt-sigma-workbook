#!/usr/bin/env python3
"""Compare exported workbook specs with the committed golden files.

The specs are deterministic (every id is a hash of a stable path), so the exact JSON a workbook model
compiles to can be committed and diffed. Any change to what the macros emit then shows up in review as
a diff of `integration_tests/expected/*.json`, instead of relying on someone having thought to assert on it.

    python scripts/check_golden.py --actual <dir of exported specs>            # compare
    python scripts/check_golden.py --actual <dir of exported specs> --update   # accept the new output

Comparison is on parsed JSON, so key order and whitespace don't matter; the diff shown is on the
key-sorted, indented form. Missing and unexpected files are failures too, so adding or removing a
workbook model can't go unnoticed.

Environment-specific ids are not part of the snapshot. Every `connectionId`, `folderId` and
`dataModelId` is replaced with a placeholder on both sides (and golden files are written that way), so
these ids come from the `sigma_connection_id`, `sigma_folder_id` and `sigma_data_model_ids` project vars
and never live in the repo. `assert_workbooks` separately checks that the specs carry exactly those
vars.
"""
from __future__ import annotations

import argparse
import difflib
import json
import sys
from pathlib import Path

DEFAULT_EXPECTED = Path(__file__).resolve().parent.parent / "integration_tests" / "expected"
MAX_DIFF_LINES = 60
# JSON keys whose string values depend on the environment, and what stands in for them.
PLACEHOLDERS = {"connectionId": "<connectionId>", "folderId": "<folderId>", "dataModelId": "<dataModelId>"}


def normalize(value):
    """A copy of parsed JSON with the environment-specific values replaced by placeholders."""
    if isinstance(value, dict):
        return {k: PLACEHOLDERS[k] if k in PLACEHOLDERS and isinstance(v, str) else normalize(v) for k, v in value.items()}
    if isinstance(value, list):
        return [normalize(item) for item in value]
    return value


def _load(path: Path):
    return normalize(json.loads(path.read_text()))


def _pretty(path: Path) -> list[str]:
    return json.dumps(_load(path), indent=2, sort_keys=True).splitlines()


def compare(actual_dir: Path, expected_dir: Path) -> list[str]:
    """Human-readable problems; empty when the two directories hold the same specs."""
    actual = {p.name: p for p in actual_dir.glob("*.json")}
    expected = {p.name: p for p in expected_dir.glob("*.json")} if expected_dir.is_dir() else {}
    problems = []
    for name in sorted(actual.keys() - expected.keys()):
        problems.append(f"{name}: compiled but has no golden file (run with --update to accept it)")
    for name in sorted(expected.keys() - actual.keys()):
        problems.append(f"{name}: golden file exists but the workbook was not compiled (run with --update to drop it)")
    for name in sorted(actual.keys() & expected.keys()):
        if _load(actual[name]) == _load(expected[name]):
            continue
        diff = list(difflib.unified_diff(_pretty(expected[name]), _pretty(actual[name]), "expected/" + name, "actual/" + name, lineterm="", n=2))
        shown = diff[:MAX_DIFF_LINES]
        if len(diff) > len(shown):
            shown.append(f"... {len(diff) - len(shown)} more diff lines")
        problems.append(f"{name}: differs from its golden file\n" + "\n".join(shown))
    return problems


def update(actual_dir: Path, expected_dir: Path) -> list[str]:
    expected_dir.mkdir(parents=True, exist_ok=True)
    for stale in expected_dir.glob("*.json"):
        stale.unlink()
    written = []
    for path in sorted(actual_dir.glob("*.json")):
        (expected_dir / path.name).write_text(json.dumps(_load(path), indent=2) + "\n")
        written.append(path.name)
    return written


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--actual", required=True, type=Path, help="directory of specs written by export_workbooks.py --out")
    parser.add_argument("--expected", type=Path, default=DEFAULT_EXPECTED)
    parser.add_argument("--update", action="store_true", help="overwrite the golden files with the actual output")
    args = parser.parse_args(argv)

    if not any(args.actual.glob("*.json")):
        print(f"error: no specs in {args.actual}", file=sys.stderr)
        return 2
    if args.update:
        names = update(args.actual, args.expected)
        print(f"updated {len(names)} golden file(s) in {args.expected}: {', '.join(names)}")
        return 0
    problems = compare(args.actual, args.expected)
    for problem in problems:
        print("FAIL " + problem)
    if problems:
        print("\nIf the change is intended, review the diff and re-run with --update (UPDATE_GOLDEN=1 for the test script).")
        return 1
    print(f"ok   {len(list(args.actual.glob('*.json')))} compiled workbook(s) match their golden files")
    return 0


if __name__ == "__main__":
    sys.exit(main())
