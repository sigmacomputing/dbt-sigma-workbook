# Integration tests

A runnable example project: one seed (`orders`), a staging model, one Sigma data model (composed with the companion [`sigma_data_models`](https://github.com/Matts52/dbt-sigma-data-models) package), and four workbook models that exercise the library in different ways. It doubles as a set of copy-pasteable examples.

## Run

```bash
pip install -r ../ci/requirements-dbt1.txt
bash ../scripts/run_integration_tests_duckdb.sh
```

No credentials or network access beyond `dbt deps` fetching the pinned `sigma_data_models` are needed; the profile writes a local DuckDB file. The script prints each step. To run the pieces by hand:

```bash
cd integration_tests
export DBT_PROFILES_DIR=$PWD
dbt deps && dbt seed && dbt run
dbt parse --no-partial-parse            # specs land in target/manifest.json
dbt run-operation assert_workbooks      # structural assertions
```

## What is in it

| Model | Shows |
| --- | --- |
| `sigma_sales_dashboard` | Everything built from primitives: two pages, KPIs with comparison / timeline / sparkline, bar (with `extend`), line, donut, pivot, a chart built on a table element, a table with a calculated column, list and date controls wired to several elements, containers and rows, a `raw` button, a divider, text. |
| `sigma_sales_simple` | The same idea in one call: `simple_dashboard`. |
| `simple_leaderboard` | `simple_leaderboard`: two dimensions ranked by one measure, plus a breakdown pivot. |
| `sigma_sales_from_data_model` | A workbook that reads the `orders` table of `sigma_sales_model`, with a per-workbook theme override. |
| `sigma_sales_model` | A Sigma data model (via `sigma_data_models`), so the interop can be checked against the real package. |

`dbt_project.yml` sets the project vars (`sigma_connection_id`, `sigma_folder_id`, `sigma_data_model_ids`, `sigma_workbook_theme`) and `flags: validate_macro_args: true`, which makes dbt check `macros/schema.yml` against the real macro signatures (CI adds `--warn-error` on dbt 1.x).

**No Sigma id is hardcoded anywhere in the tests.** The connection, folder and data model ids are project vars that read `SIGMA_CONNECTION_ID`, `SIGMA_FOLDER_ID` and `SIGMA_DATA_MODEL_ID` and otherwise default to `00000000-0000-0000-0000-0000000000NN` placeholders. The assertions compare the compiled specs with those vars, the last step of the script re-runs them under a `--vars` override, and the golden files store `<connectionId>`, `<folderId>` and `<dataModelId>` instead of values, so the suite passes whatever ids you supply. `scripts/test_no_leaked_ids.py` fails the build if a real-looking id, an email address, a non-public Sigma host or a local path is committed anywhere in the repository.

## What the suite checks

1. **Builds and parses** on DuckDB with no warehouse connection (`dbt parse` alone produces the specs).
2. **`assert_workbooks`** (`macros/assert_workbook.sql`), on every workbook:
   - the `POST /v2/workbooks` body: `name`, `folderId`, `contents.{schemaVersion, kind, pages, elements, settings, layout}`; no `workbookId` on a first create;
   - no private (`_`-prefixed) key leaks, no unresolved data-model placeholder, no unresolved color marker;
   - unique element ids; unique column ids per element; every `source.elementId`, table `order`/`sort`, KPI `value`, chart axis/color/value, pivot grouping, control filter and list-control source resolves to something that exists;
   - every element appears in the layout exactly once, containers as `<Container>`, every page has a `<Page>`;
   - and on the specific workbooks: element counts and kinds; control targets; KPI comparison / timeline / sparkline fields; `extend()` and `raw()` output; unqualified formula references carry their passthrough column; value/comparison and slice/hole are separate columns; child elements reference the parent's columns; control ids can't collide with columns; theme defaults, project var and per-workbook override; the `spec` output format and its legacy layout tags; data-model element ids equal those `sigma_data_models` generated; `ref()`s inside macros appear in `depends_on`; identical input compiles to identical output.
   `assert_workbooks` checks every model that carries a workbook spec (it discovers them from the graph), so a new workbook model gets the structural checks without editing the macro.
3. **Export**: `scripts/export_workbooks.py` writes one JSON file per workbook and its `--check` passes.
4. **Golden files**: the exported specs are deterministic, so `integration_tests/expected/*.json` holds the exact JSON each workbook model compiles to, and `scripts/check_golden.py` compares them (parsed, so key order and whitespace don't matter). Any change to what the macros emit, however small, shows up as a diff. A workbook model with no golden file, or a golden file with no model, also fails. When a change is intended, review the diff and accept it:

   ```bash
   UPDATE_GOLDEN=1 bash scripts/run_integration_tests_duckdb.sh
   git diff integration_tests/expected
   ```
5. **Schema conformance**: `scripts/validate_against_sigma_schema.py` validates each spec against `integration_tests/schema/create_workbook_request.schema.json.gz`, the request body of `POST /v2/workbooks` extracted from [Sigma's public OpenAPI](https://assets.sigmacomputing.com/openapi/public-rest-api/sigma-computing-public-rest-api.json). Without `jsonschema` installed this step is skipped locally; CI sets `REQUIRE_JSONSCHEMA=1`, so there it fails instead.
6. **Rejection** (`macros/assert_rejected.sql`): 30 invalid inputs (empty workbook/page, duplicate page names or element ids, unknown color tokens, bad sort directions, a table with no columns, a pivot with no axes, an over-wide element, malformed sources and fields, unsupported formats or output format, controls without or with foreign targets, unknown chart/filter types, a control id that collides with a column, misuse of `extend` / `raw`, a missing connection id, a leaderboard with no dimensions). Each is listed in `negative_cases.txt` with the text its error must contain. The script fails if the macro succeeds, **or** fails with any other message (a typo in the test, an unrelated error), **or** if a macro in `assert_rejected.sql` has no entry in `negative_cases.txt` (or the reverse), so no case can go unrun. To add one: write the `assert_*_rejected` macro, run it, and put its message in `negative_cases.txt`.

Separately, `python -m unittest discover -s scripts -p "test_*.py"` runs the script tests:

- `test_export_workbooks.py`: the export/push script against a fake Sigma API on localhost (auth, create, dry run, update, legacy endpoints, HTTP errors, refusal to push with problems).
- `test_no_leaked_ids.py`: scans the tracked files for real-looking ids (only placeholders are allowed), email addresses (only `example.com`), non-public Sigma hosts and local paths, and proves the scanner can find each kind. It also runs as a pre-commit hook (`pre-commit install` once per clone), so a leak is stopped before it is committed rather than after.
- `test_check_golden.py`: the golden comparison (changed values, list order, missing and unexpected files, truncated diffs, `--update`), plus a sanity check of the committed golden files.
- `test_validate_against_sigma_schema.py`: proves the schema check can fail. It breaks the golden specs (missing required fields, unknown element kind, wrong type, bad enum, bad source kind) and requires the validator to object. Note that the published schema alone accepts a body with no `contents`, because the request is a union that includes the legacy `spec` shape; the export step asserts `contents` for that reason.

## What it does not check

Nothing here talks to Sigma: CI has no credentials. The schema check catches missing required fields, wrong types and enum values, and unknown element kinds, but not unknown extra properties or invalid formulas. Sigma's own validator does; run `SIGMA_CONNECTION_ID=<your connection id> dbt parse` and then `python scripts/export_workbooks.py --push --dry-run` against your organization to use it (it creates nothing). That is how the layout-tag, column-channel and control-id problems recorded in [`docs/design.md`](../docs/design.md) were found.

## Refreshing the schema

When Sigma changes its API, `python scripts/validate_against_sigma_schema.py --refresh` re-downloads the OpenAPI document and rewrites `schema/create_workbook_request.schema.json.gz`.

## Switching adapters

The macros emit JSON only, so nothing is adapter-specific. `profiles.yml` also has a `snowflake` target with dummy credentials to document the intended production adapter: `dbt parse --target snowflake` needs no connection.
