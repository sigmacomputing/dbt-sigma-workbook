# Integration tests

A runnable example project: one seed (`orders`), a staging model, one Sigma data model (composed with the companion [`sigma_data_models`](https://github.com/Matts52/dbt-sigma-data-models) package), and three workbook models that exercise the library three ways. It doubles as a set of copy-pasteable examples.

## Run

```bash
pip install -r ../ci/requirements-dbt1.txt      # or ../ci/requirements-dbt2.txt for dbt 2.x
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
| `sigma_sales_from_data_model` | A workbook that reads the `orders` table of `sigma_sales_model`, with a per-workbook theme override. |
| `sigma_sales_model` | A Sigma data model (via `sigma_data_models`), so the interop can be checked against the real package. |

`dbt_project.yml` sets the project vars (`sigma_connection_id`, `sigma_folder_id`, `sigma_data_model_ids`, `sigma_workbook_theme`) and `flags: validate_macro_args: true`, which makes dbt check `macros/schema.yml` against the real macro signatures (CI adds `--warn-error` on dbt 1.x).

## What the suite checks

1. **Builds and parses** on DuckDB with no warehouse connection (`dbt parse` alone produces the specs).
2. **`assert_workbooks`** (`macros/assert_workbook.sql`), on every workbook:
   - the `POST /v2/workbooks` body: `name`, `folderId`, `contents.{schemaVersion, kind, pages, elements, settings, layout}`; no `workbookId` on a first create;
   - no private (`_`-prefixed) key leaks, no unresolved data-model placeholder, no unresolved color marker;
   - unique element ids; unique column ids per element; every `source.elementId`, table `order`/`sort`, KPI `value`, chart axis/color/value, pivot grouping, control filter and list-control source resolves to something that exists;
   - every element appears in the layout exactly once, containers as `<Container>`, every page has a `<Page>`;
   - and on the specific workbooks: element counts and kinds; control targets; KPI comparison / timeline / sparkline fields; `extend()` and `raw()` output; unqualified formula references carry their passthrough column; value/comparison and slice/hole are separate columns; child elements reference the parent's columns; control ids can't collide with columns; theme defaults, project var and per-workbook override; the `spec` output format and its legacy layout tags; data-model element ids equal those `sigma_data_models` generated; `ref()`s inside macros appear in `depends_on`; identical input compiles to identical output.
3. **Export**: `scripts/export_workbooks.py` writes one JSON file per workbook and its `--check` passes.
4. **Schema conformance**: `scripts/validate_against_sigma_schema.py` validates each spec against `integration_tests/schema/create_workbook_request.schema.json.gz`, the request body of `POST /v2/workbooks` extracted from [Sigma's public OpenAPI](https://assets.sigmacomputing.com/openapi/public-rest-api/sigma-computing-public-rest-api.json).
5. **Rejection** (`macros/assert_rejected.sql`): 28 invalid inputs (empty workbook/page, duplicate page names or element ids, unknown color tokens, bad sort directions, a table with no columns, a pivot with no axes, an over-wide element, malformed sources and fields, unsupported formats, controls without or with foreign targets, unknown chart/filter types, a control id that collides with a column, misuse of `extend` / `raw`, a missing connection id). Each must exit non-zero; the script fails if any succeeds.

Separately, `python -m unittest scripts/test_export_workbooks.py` tests the export/push script against a fake Sigma API running on localhost (auth, create, dry run, update, legacy endpoints, HTTP errors, refusal to push with problems).

## What it does not check

Nothing here talks to Sigma: CI has no credentials. The schema check catches missing required fields, wrong types and enum values, and unknown element kinds, but not unknown extra properties or invalid formulas. Sigma's own validator does; run `python scripts/export_workbooks.py --push --dry-run` against your organization to use it (it creates nothing). That is how the layout-tag, column-channel and control-id problems recorded in [`docs/design.md`](../docs/design.md) were found.

## Refreshing the schema

When Sigma changes its API, `python scripts/validate_against_sigma_schema.py --refresh` re-downloads the OpenAPI document and rewrites `schema/create_workbook_request.schema.json.gz`.

## Switching adapters

The macros emit JSON only, so nothing is adapter-specific. `profiles.yml` also has a `snowflake` target with dummy credentials to document the intended production adapter: `dbt parse --target snowflake` needs no connection.
