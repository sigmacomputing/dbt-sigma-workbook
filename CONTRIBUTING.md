# Contributing

Issues and pull requests are welcome.

## Getting set up

```bash
python -m venv .venv && . .venv/bin/activate
pip install -r ci/requirements-dbt1.txt
pip install pre-commit && pre-commit install   # runs the leak guard before every commit
bash scripts/run_integration_tests_duckdb.sh   # the whole suite; no credentials needed
python -m unittest discover -s scripts -p "test_*.py"
```

CI runs the suite on dbt 1.x and dbt 2.x, and both must pass. [`AGENTS.md`](AGENTS.md) lists the conventions and dbt Jinja gotchas (no `**kwargs`, deterministic ids, late-bound colors); read it before writing macros.

## Changing behavior

- Adding, renaming or removing a macro argument: update [`macros/schema.yml`](macros/schema.yml), or the build fails.
- Adding an element: follow "Adding an element" in [`docs/design.md`](docs/design.md), then use it in an integration workbook and assert on it.
- Expected compile errors get a negative test in `assert_rejected.sql`.
- If the change alters what elements look like, run `python scripts/export_workbooks.py --push --dry-run` against a Sigma organization and mention the result in the PR.

## Please do not commit

Real Sigma ids, hosts, email addresses, credentials or local paths. The pre-commit hook and CI reject them; use obviously fake values in examples.

## Pull requests

Keep them focused, say what changed and why, and note anything you could not test (for example, rendering in Sigma).
