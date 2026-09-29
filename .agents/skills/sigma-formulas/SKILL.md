---
name: sigma-formulas
description: Write and debug Sigma formulas used in dbt-sigma-workbook macros (kpi values, chart axes, field(), control targets, compare_to). Use when the user asks for a metric, measure, calculated column or filter expression, or when `--push --dry-run` rejects a formula.
---

# Sigma formulas in dbt-sigma-workbook

Every "field" argument in this package (`kpi(value=...)`, `bar_chart(x=, y=, color=)`, `field(...)`, `compare_to=`, `table` columns) is either a plain column name or a Sigma formula string. The package does not parse formulas; Sigma validates them. Always confirm with `python scripts/export_workbooks.py --push --dry-run`.

The authoritative reference is <https://help.sigmacomputing.com/docs/formula-reference>. Check it before using a function you are not sure exists; do not invent function names.

## How the package reads a field string

- All-lowercase with no `[`, `(` or uppercase letter (`region`, `order_date`): a source column. It is title-cased to `[Order Date]`, and qualified with the table for warehouse and data model sources.
- Anything containing `[`, `(` or an uppercase letter: a formula, emitted as written.
- `sigma_workbook.field('Sum([Amount])', name='Revenue', format=sigma_workbook.format_currency())` adds a display name and number format.
- Write column references **unqualified** (`[Amount]`, not `[stg_orders/Amount]`). The package adds the qualified passthrough column itself; see AGENTS.md.

## Syntax essentials

- Columns are in square brackets: `[Order Date]`. Source-qualified: `[TABLE/Order Date]`. Use the name Sigma shows, usually Title Case with spaces.
- Function names are PascalCase, for example `Sum`, `Avg`, `Min`, `Max`, `Count`, `CountDistinct`, `CountIf`, `SumIf`, `If`, `Switch`, `Coalesce`, `IsNull`, `DateTrunc`, `DateAdd`, `DateDiff`, `Today`, `Round`, `Text`, `Number`, `Concat`, `Lower`, `Upper`, `Contains`. Verify exact names and argument order in the reference.
- Strings use double quotes: `"month"`, `"West"`.
- Aggregates (`Sum`, `Count`, ...) collapse rows to the element's grouping. Row-level functions (`DateTrunc`, `If`, `Round`) run per row. A chart's dimension axis is usually row-level (`DateTrunc("month", [Order Date])`); its measure axis is an aggregate.
- Controls are referenced by their `controlId` in the same namespace as columns. The package defaults it to `<name>-control` (`Region` -> `[region-control]`), so a control never collides with a column.

## Writing them inside dbt Jinja

Use single quotes around the Jinja string so Sigma's double quotes need no escaping:

```jinja
sigma_workbook.line_chart(orders, 'DateTrunc("month", [Order Date])', 'Sum([Amount])', name='Revenue by month')
sigma_workbook.kpi(orders, 'CountIf([Status] = "returned")', name='Returns')
sigma_workbook.kpi(orders, 'Sum([Amount])', name='Revenue', compare_to='Sum([Target Amount])')
```

A formula containing a single quote needs Jinja escaping; prefer restructuring it to use double quotes.

## Common patterns

| Want | Formula |
| --- | --- |
| Revenue | `Sum([Amount])` |
| Distinct customers | `CountDistinct([Customer Id])` |
| Conditional count | `CountIf([Status] = "returned")` |
| Rate | `CountIf([Status] = "returned") / Count()` (format with `format_percent()`) |
| Month bucket | `DateTrunc("month", [Order Date])` |
| Fallback value | `Coalesce([Region], "Unknown")` |
| Bucketing | `If([Amount] > 1000, "Large", "Small")` |

## Gotchas

- A column feeds one channel of an element only. Using the same measure as a KPI's value and its comparison is fine; the package creates separate columns (see AGENTS.md).
- `--push --dry-run` does not resolve unqualified `[Column]` references, so a typo in a column name can pass validation and still fail in the UI. Check names against the real table.
- Aggregating an already-aggregated value, or mixing aggregate and row-level expressions on one axis, is the usual cause of a dry-run rejection.
- Do not put secrets or real customer data in examples or tests.
