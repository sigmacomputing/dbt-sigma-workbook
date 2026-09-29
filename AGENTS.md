# AGENTS.md

Guidance for AI coding agents (and humans) working in this repository.

## What this is

`dbt-sigma-workbook` composes [Sigma workbooks](https://help.sigmacomputing.com/docs/manage-workbooks-as-code) from dbt macros. The spec is pure compile-time JSON, attached to a dbt model's `meta.sigma_workbook` via `sigma_workbook.materialize()`, and read from `manifest.json`. The macros never call Sigma or the warehouse. `scripts/export_workbooks.py` is the optional last mile (write files / push to the Sigma API).

Read `README.md` for usage and `docs/design.md` for the reasoning, the composability critique and the extension recipe. For Sigma formulas (kpi values, axes, `field()`), see the skill in `.agents/skills/sigma-formulas/SKILL.md`.

## Commands

```bash
pip install -r ci/requirements-dbt1.txt        # dbt 1.x;  ci/requirements-dbt2.txt for dbt 2.x
bash scripts/run_integration_tests_duckdb.sh   # the whole suite (DuckDB, no credentials)
python -m unittest discover -s scripts -p "test_*.py"
pip install pre-commit && pre-commit install   # once per clone: runs the leak guard before every commit
```

The script honors `DBT`, `PYTHON` and `PARSE_FLAGS`. CI runs it on dbt 1.x (with `PARSE_FLAGS=--warn-error`) and on dbt 2.x. **Both must pass**; dbt 2.x is the stricter of the two.

Live validation against Sigma (needs credentials, creates nothing): `python scripts/export_workbooks.py --push --dry-run`. Do this after any change to what elements look like; it caught real bugs that no offline check can (see `docs/design.md`).

## Layout

- `macros/core` ids, string/dict helpers, `fail()`. `macros/theme` design tokens + late-bound colors. `macros/data` sources, fields, formats. `macros/elements` one file per element family, plus `control`, `escape_hatches`. `macros/layout` grid placement + XML. `macros/workbook` `page`/`workbook`/`materialize`. `macros/components` composites and `simple_dashboard`.
- `macros/schema.yml` documents every public macro. **dbt validates it against the signatures** (`validate_macro_args`); adding, renaming or removing an argument means updating it, or the build fails.
- `integration_tests/` is a real dbt project (`packages.yml: local: ../`). `assert_workbook.sql` = positive assertions, `assert_rejected.sql` = expected compile errors, each listed in `negative_cases.txt` with the message it must raise (the script checks the two agree). `expected/*.json` = golden copies of every compiled workbook; after an intended change to emitted JSON, run `UPDATE_GOLDEN=1 bash scripts/run_integration_tests_duckdb.sh` and review the diff.

## Conventions and gotchas

- **Elements are dicts.** Keys starting with `_` are private (layout hints, `_source`, `_children`) and stripped by `workbook()`. Never put a private key in output another way.
- **dbt Jinja limits.** No `**kwargs`. Dict keys named `items`/`keys`/`values` collide with dict methods: use `el['values']`, never `el.values`. `{% set %}` inside a `for` doesn't leak: use `namespace`. Comments (`{# #}`) can't sit inside a `{% ... %}` tag. No `modules.re` (not portable to dbt 2): parse strings with `split`.
- **Every id is a hash of a stable path** (`freeze_id`). Never use timestamps, counters, or `run_started_at`. Column ids include the *role* (channel) because Sigma allows a column on one channel only.
- **Unqualified formula references** (`Sum([Amount])`) get a qualified passthrough column (`[table/Amount]`) added by `add_column`; that is Sigma's own export convention. Keep it.
- **Colors are late-bound**: element macros call `color_ref('primary')` (a marker), never `color()` (a hex), so a workbook-level `theme=` reaches them. `workbook()` resolves the markers.
- **Two output formats**: `contents` (default; `POST /v2/workbooks`, layout tags `<Element>`/`<Container>`) and `spec` (deprecated; nested pages, `<LayoutElement>`/`<GridContainer>`). The current API rejects the legacy tags.
- **Never commit a real Sigma id, email address, internal host or local path.** Connection, folder and data model ids come from project vars (`SIGMA_*` environment variables with `00000000-0000-0000-0000-0000000000NN` placeholder defaults); use `<your-...-id>` placeholders in docs. `scripts/test_no_leaked_ids.py` enforces this: it runs as a pre-commit hook (`.pre-commit-config.yaml`, after `pre-commit install`) and CI fails if it is broken. Git history is permanent, so the fix for a leak that was already committed is not a follow-up commit.
- **Sigma names win.** Use Sigma's own field names in emitted JSON. Check the OpenAPI schema (`integration_tests/schema/`) before inventing a field.
- Fail with `sigma_workbook.fail('macro_name', 'message')` so errors carry the macro name; add a matching `assert_*_rejected` negative test.
- Dependencies in `ci/` are pinned to versions at least three days old. Keep it that way when refreshing.

## Adding an element

See "Adding an element" in `docs/design.md`. In short: a macro that calls `new_element`, `add_column(s)` (with a `role`), stores `_source`, applies `card_style`; then document it in `macros/schema.yml`, use it in an integration workbook, assert on it, and dry-run it against Sigma.
