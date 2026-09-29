#!/bin/bash
# Runs the whole integration suite against DuckDB. No credentials, no network beyond `dbt deps`
# fetching the pinned sigma_data_models package.
#
#   ./scripts/run_integration_tests_duckdb.sh
#
# Environment:
#   DBT          the dbt executable to use (default: `dbt` on PATH) - 1.x and 2.x both work
#   PYTHON       the Python used for scripts/ (default: python3); `pip install jsonschema` enables step 5b
#   PARSE_FLAGS  extra flags for `dbt parse`, e.g. --warn-error (dbt 1.x)
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INT_TESTS_DIR="$REPO_ROOT/integration_tests"
DBT="${DBT:-dbt}"
PYTHON="${PYTHON:-python3}"
export DBT_PROFILES_DIR="$INT_TESTS_DIR"

echo "=== dbt-sigma-workbook integration tests (DuckDB) ==="
$DBT --version | head -3
echo ""

mkdir -p "$REPO_ROOT/duckdb"
cd "$INT_TESTS_DIR"

echo "1. Installing dependencies..."
$DBT deps

echo ""
echo "2. Loading seed data and building the models..."
$DBT seed
$DBT run

echo ""
echo "3. Parsing without a warehouse connection (no partial parse) - specs land in the manifest..."
$DBT parse --no-partial-parse $PARSE_FLAGS

echo ""
echo "4. Asserting the shape of every compiled workbook..."
$DBT run-operation assert_workbooks

echo ""
echo "5. Exporting specs from the manifest and validating the JSON files..."
OUT_DIR="$(mktemp -d)"
"$PYTHON" "$REPO_ROOT/scripts/export_workbooks.py" --manifest target/manifest.json --out "$OUT_DIR"
for f in sigma_sales_dashboard sigma_sales_simple sigma_sales_from_data_model; do
  test -s "$OUT_DIR/$f.json" || { echo "missing export: $f.json"; exit 1; }
  "$PYTHON" -c "import json,sys; d=json.load(open(sys.argv[1])); c=d['contents']; assert d['name'] and c['schemaVersion']==1 and c['pages'] and c['elements'], 'bad spec'" "$OUT_DIR/$f.json"
  echo "exported $f.json"
done
# The offline check the deploy script performs before it would ever call Sigma:
"$PYTHON" "$REPO_ROOT/scripts/export_workbooks.py" --manifest target/manifest.json --out "$OUT_DIR" --check

echo ""
echo "5b. Validating against Sigma's published request schema (POST /v2/workbooks)..."
if "$PYTHON" -c "import jsonschema" 2>/dev/null; then
  "$PYTHON" "$REPO_ROOT/scripts/validate_against_sigma_schema.py" --manifest target/manifest.json
else
  echo "jsonschema is not installed - skipping (pip install jsonschema to enable)."
fi

echo ""
echo "6. Asserting invalid input is rejected with a compiler error..."
NEGATIVE_MACROS="
assert_empty_workbook_rejected
assert_empty_page_rejected
assert_duplicate_page_name_rejected
assert_duplicate_element_id_rejected
assert_unnamed_element_rejected
assert_unknown_color_token_rejected
assert_unknown_color_ref_rejected
assert_bad_sort_direction_rejected
assert_table_without_columns_rejected
assert_pivot_without_axes_rejected
assert_empty_container_rejected
assert_overwide_element_rejected
assert_bad_source_rejected
assert_bad_warehouse_path_rejected
assert_unsupported_format_kind_rejected
assert_unsupported_format_option_rejected
assert_control_without_targets_rejected
assert_control_with_foreign_target_rejected
assert_unknown_chart_type_rejected
assert_unknown_filter_type_rejected
assert_empty_simple_dashboard_rejected
assert_malformed_field_rejected
assert_control_id_column_collision_rejected
assert_extend_id_rejected
assert_extend_foreign_element_rejected
assert_raw_without_key_rejected
assert_raw_private_key_rejected
"
LOG="$(mktemp)"
for macro in $NEGATIVE_MACROS; do
  set +e
  $DBT run-operation "$macro" > "$LOG" 2>&1
  status=$?
  set -e
  if [ $status -eq 0 ]; then
    echo "Expected $macro to raise a compiler error, but it succeeded:"
    cat "$LOG"
    exit 1
  fi
  echo "  $macro was correctly rejected."
done

# Needs the project var blanked, so it runs on its own.
set +e
$DBT run-operation assert_missing_connection_id_rejected --vars "{sigma_connection_id: ''}" > "$LOG" 2>&1
status=$?
set -e
if [ $status -eq 0 ]; then
  echo "Expected assert_missing_connection_id_rejected to raise a compiler error, but it succeeded:"
  cat "$LOG"
  exit 1
fi
echo "  assert_missing_connection_id_rejected was correctly rejected."

echo ""
echo "=== All tests passed! ==="
