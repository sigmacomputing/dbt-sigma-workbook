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
#   REQUIRE_JSONSCHEMA  set to fail (rather than skip) step 5b when jsonschema is missing; CI sets it
#   UPDATE_GOLDEN       set to rewrite integration_tests/expected/ with the current output (review the diff!)
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
LOG="$(mktemp)"
trap 'rm -rf "$OUT_DIR" "$LOG"' EXIT
"$PYTHON" "$REPO_ROOT/scripts/export_workbooks.py" --manifest target/manifest.json --out "$OUT_DIR"
EXPORTED=0
for f in "$OUT_DIR"/*.json; do
  test -s "$f" || { echo "empty export: $f"; exit 1; }
  "$PYTHON" -c "import json,sys; d=json.load(open(sys.argv[1])); c=d['contents']; assert d['name'] and c['schemaVersion']==1 and c['pages'] and c['elements'], 'bad spec'" "$f"
  echo "exported $(basename "$f")"
  EXPORTED=$((EXPORTED + 1))
done
# Guards against the glob silently matching nothing.
[ "$EXPORTED" -ge 3 ] || { echo "expected at least 3 exported workbooks, found $EXPORTED"; exit 1; }
# The offline check the deploy script performs before it would ever call Sigma:
"$PYTHON" "$REPO_ROOT/scripts/export_workbooks.py" --manifest target/manifest.json --out "$OUT_DIR" --check

echo ""
echo "5a. Comparing every compiled workbook with its golden file (integration_tests/expected/)..."
# The specs are deterministic, so the exact JSON is committed. UPDATE_GOLDEN=1 accepts new output.
if [ -n "$UPDATE_GOLDEN" ]; then
  "$PYTHON" "$REPO_ROOT/scripts/check_golden.py" --actual "$OUT_DIR" --update
else
  "$PYTHON" "$REPO_ROOT/scripts/check_golden.py" --actual "$OUT_DIR"
fi

echo ""
echo "5b. Validating against Sigma's published request schema (POST /v2/workbooks)..."
if "$PYTHON" -c "import jsonschema" 2>/dev/null; then
  "$PYTHON" "$REPO_ROOT/scripts/validate_against_sigma_schema.py" --manifest target/manifest.json
elif [ -n "$REQUIRE_JSONSCHEMA" ]; then
  echo "jsonschema is not installed but REQUIRE_JSONSCHEMA is set."
  exit 1
else
  echo "jsonschema is not installed - skipping (pip install jsonschema to enable)."
fi

echo ""
echo "6. Asserting invalid input is rejected with the expected compiler error..."
# negative_cases.txt lists each macro and the text its error must contain, so a case can't pass because
# of a typo in the test or an unrelated error. The macros in assert_rejected.sql and the entries in that
# file must match one to one, so none can go unrun.
CASES="$INT_TESTS_DIR/negative_cases.txt"
trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }
DEFINED="$(grep -o 'macro assert_[a-z_]*_rejected' "$INT_TESTS_DIR/macros/assert_rejected.sql" | awk '{print $2}' | sort)"
LISTED="$(grep -v '^[[:space:]]*#' "$CASES" | grep -v '^[[:space:]]*$' | cut -d'|' -f1 | tr -d ' ' | sort)"
if [ "$DEFINED" != "$LISTED" ]; then
  echo "assert_rejected.sql and negative_cases.txt disagree (< defined only, > listed only):"
  diff <(echo "$DEFINED") <(echo "$LISTED") || true
  exit 1
fi
CASE_COUNT=0
while IFS='|' read -r macro expected vars; do
  macro="$(trim "$macro")"
  case "$macro" in ''|'#'*) continue ;; esac
  expected="$(trim "$expected")"
  vars="$(trim "$vars")"
  set +e
  if [ -n "$vars" ]; then
    $DBT run-operation "$macro" --vars "$vars" > "$LOG" 2>&1
  else
    $DBT run-operation "$macro" > "$LOG" 2>&1
  fi
  status=$?
  set -e
  if [ $status -eq 0 ]; then
    echo "Expected $macro to raise a compiler error, but it succeeded:"
    cat "$LOG"
    exit 1
  fi
  if ! grep -qF -- "$expected" "$LOG"; then
    echo "$macro failed, but not with the expected error."
    echo "  expected to contain: $expected"
    echo "  dbt said:"
    sed 's/^/    /' "$LOG"
    exit 1
  fi
  echo "  $macro was rejected: $expected"
  CASE_COUNT=$((CASE_COUNT + 1))
done < "$CASES"
[ "$CASE_COUNT" -ge 1 ] || { echo "no negative cases ran"; exit 1; }
echo "  $CASE_COUNT negative cases passed."

echo ""
echo "7. Re-running the assertions with different Sigma ids..."
# The connection, folder and data model ids are project vars (integration_tests/dbt_project.yml, or the
# SIGMA_CONNECTION_ID / SIGMA_FOLDER_ID / SIGMA_DATA_MODEL_ID environment variables). The assertions
# compare the compiled specs with those vars, so they only pass under an override if every id flows
# from the vars and none is baked into the macros or the tests.
OVERRIDE="{sigma_connection_id: connection-from-a-vars-override, sigma_folder_id: folder-from-a-vars-override, sigma_data_model_ids: {sigma_sales_model: data-model-from-a-vars-override}}"
$DBT run-operation assert_workbooks --vars "$OVERRIDE" > "$LOG" 2>&1 || { cat "$LOG"; exit 1; }
grep -q "all assertions passed" "$LOG" || { echo "assert_workbooks did not report success under the override:"; cat "$LOG"; exit 1; }
echo "  assertions passed with the connection, folder and data model ids overridden."

echo ""
echo "=== All tests passed! ==="
