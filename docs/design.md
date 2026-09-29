# Design notes and a critique of the abstraction

This is the reasoning behind the package's shape, followed by an honest look at how composable it really is, what that review changed, and what is still open.

## The shape

```
sources ─┐
fields  ─┼─► elements ─► composites ─► page ─► workbook ─► materialize ─► manifest.json ─► (export script) ─► Sigma
theme   ─┘        ▲
controls ─────────┘ (target elements)
```

Four decisions carry most of the design:

1. **A workbook is a dbt model; the spec is compile-time JSON.** The macros never touch Sigma or the warehouse. The spec is stored in `config.meta.sigma_workbook`, so it is in `manifest.json` after `dbt parse`, diffable in PRs, and visible to any tool that reads the manifest. This mirrors `dbt-sigma-data-models`, so a project with both has one mental model and one set of vars (`sigma_connection_id`, `sigma_folder_id`).
2. **Everything is a plain dict.** A source, a field, an element and a whole workbook are all dicts in (nearly) Sigma's own shape. Because they are dicts, they can be built by any macro, held in variables, passed between macros, mutated, and inspected in tests. There are no classes and no hidden state.
3. **Layers only depend downward.** Elements never know about pages; composites (`row`, `kpi_row`, `dashboard_page`, `simple_dashboard`, `simple_leaderboard`) are written using nothing but the public element macros; `workbook()` is the only place that knows the output format. A composite is therefore also documentation: it is what you would write yourself.
4. **Sigma's shape wins over invention.** Field names (`xAxis.columnId`, `comparisonColumn`, `holeValue`), the passthrough-column convention, the layout grid, the theme settings are all Sigma's. Where the package adds a private field (`_w`, `_h`, `_children`, `_source`) it is stripped before output.

Deterministic ids follow from (1): every id is a hash of a stable path (kind + name/key for elements, formula + role for columns), so identical input gives byte-identical output and re-deploys are idempotent.

## What live validation taught us

The first version was built from the help-center examples. Running its output through Sigma's `dryRun` validator against a real organization found four things that reading the docs did not:

| Finding | Cause | Fix |
| --- | --- | --- |
| `unknown element <LayoutElement> ... expected Element, Container, or TabbedContainer` | The help-center examples show the *deprecated* `/spec` endpoints' layout vocabulary; `POST /v2/workbooks` wants `<Element>` / `<Container>`. | Layout tags depend on the output format. |
| `Column '...' is referenced from both 'value' and 'comparison'; a column can only be on one channel at a time` | Columns were shared by formula, so `compare_to='Count()'` reused the value column. | Column ids include a *role* (x, y, color, comparison, hole ...). |
| `Circular dependency detected` on a control | A control called "Duration" has `controlId` `duration`, the same name a formula uses for the column `[Duration]`. | Default `controlId` is `<name>-control`; `workbook()` rejects a collision. |
| (not an error) `Sum([NoSuchColumn])` validates | Sigma's dry run does not resolve unqualified references. | Follow Sigma's export convention: an unqualified reference always comes with its qualified passthrough column. |

It also confirmed things that had been assumptions: the `[Table/Column]` prefix rule for warehouse and data model sources (tested against a real data model), child elements, every modeled chart type, controls, pivots, and per-workbook themes are all accepted.

## Is it as composable and abstracted as it can be?

Short answer: composable enough that the common cases need no escape, and the escape exists for the rest; not as abstract as it could be, deliberately. The review, by principle:

### What holds up

- **Closure.** Every constructor returns the same kind of thing it accepts: sources go into elements, elements into pages and into other elements (`source=`), controls take elements, composites take and return elements, `page()` flattens lists of them. `simple_dashboard` is written with the public API only; nothing in it is privileged. That property is tested: the integration workbooks are built three ways (primitives, `simple_dashboard`, data-model source) and go through one validator.
- **One place per concern.** Color decisions live in the theme; id derivation in `freeze_id`; layout in `layout.sql`; output format in `workbook()`. Changing the layout tags for a new API generation touched one file.
- **Late binding where it matters.** Element colors are markers resolved when the workbook is assembled, so a workbook-level `theme=` recolors elements built earlier. Without it, every element macro would need a `theme` argument.
- **Fail early, name the line.** Empty pages, duplicate names, colliding ids, bad tokens, malformed fields, control/column clashes all fail at `dbt parse` with the macro that caught them. 28 kinds of invalid input are pinned by tests.

### Where it falls short, and what was done about it

| Weakness found in review | Status |
| --- | --- |
| No way to set a Sigma option the macros do not expose, or use an element kind they do not model, without abandoning the library. | **Fixed**: `extend()` (deep-merge raw properties onto an element) and `raw()` (any kind, still laid out and id-checked). Both are tested and used in the integration workbook. |
| Per-workbook theme did not reach element colors (found by the tests, not by inspection). | **Fixed**: late-bound `__color:token__` markers. |
| Column ids collided across channels; unqualified formula references had no backing column. | **Fixed**: roles in ids; automatic passthrough columns. |
| Controls silently depended on call order: build them after the elements they target. | **Documented**; enforced by requiring `(element, field)` targets. A control cannot be built without the element existing, so the wrong order is a compile error rather than silent. |
| Chart macros repeat a long argument list. | **Accepted**: dbt's Jinja has no `**kwargs`. The repetition is confined to `xy_chart` / `part_to_whole`, which the public macros feed, and `extend()` covers the long tail. |
| `simple_dashboard` accepts data (dicts), a second calling convention next to the macros. | **Accepted**: it is a convenience over the primitives, with a `chart_from_spec` dispatcher that is itself a public macro. Nothing else depends on the dict convention. |

### Still open (not done, on purpose or for lack of information)

- **Layout is flow-only.** There is no `x`/`y` pinning, no row spanning, no per-container column count. A `place()`-level `at=(col, row)` argument would be a small change, but not one to make before seeing what real dashboards need.
- **Modeled element set is small.** Missing: maps, combo / waterfall / funnel / gauge / sankey / treemap / box charts, input tables, buttons with actions, forms, images, embeds, tabbed containers, modals, conditional formatting, reference marks, trellis. `raw()` reaches all of them, but they carry no defaults or validation. Adding an element is mechanical: a macro that calls `new_element`, `add_column(s)`, and `card_style`.
- **Sources at parse time.** `from_ref` builds a path from `target` rather than reading the referenced relation, because `ref()` cannot resolve other models at parse time. A project with `generate_schema_name` overrides has to pass `schema=`. A possible improvement is a small dispatchable macro (`sigma_workbook__relation_path`) users override once.
- **Formulas are opaque strings.** Sigma validates them (`--push --dry-run`); the package does not. A tiny formula builder (`sigma_workbook.sum('amount')`) would help typos but not semantics, and would need to track Sigma's function set.
- **Sigma-side identity.** Ids are stable at compile time, but Sigma may assign its own on first create; the package does not read them back. `workbook_id=` updates an existing workbook (a full replace of its contents) but there is no drift detection.
- **Controls target charts/KPIs with the `table` filter kind.** The schema documents `table` sources for filters; dry run accepts the result, and it is the same shape Sigma's own controls use for non-table targets, and it has been checked in a rendered workbook.
- **Rendering is checked by hand.** Generated workbooks have been pushed to a real organization and opened in Sigma's UI, but CI has no Sigma credentials, so appearance is not covered by automated tests.

## Adding an element (the extension recipe)

Every element macro follows one pattern; a new one is 20-40 lines. This one is illustrative (look up the real field names for the kind in Sigma's schema first):

```jinja
{% macro gauge(source, value, name=none, key=none, w=6, h=6, style=none) %}
{% set source = sigma_workbook.resolve_source(source, 'gauge') %}                 {# 1. normalize the source #}
{% set el = sigma_workbook.new_element('gauge-chart', 'gauge', key, name, w, h) %}  {# 2. id + layout footprint #}
{% set cols = [] %}
{% set value_id = sigma_workbook.add_column(cols, el['id'], value, source, 'gauge', 'value') %}  {# 3. fields -> columns #}
{% do el.update({"source": source, "columns": cols, "value": {"columnId": value_id}, "_source": source}) %}
{% do sigma_workbook.apply_titles(el, name, none) %}
{% do el.update(sigma_workbook.compact({"style": sigma_workbook.card_style(style)})) %}   {# 4. house style #}
{% do return(el) %}
{% endmacro %}
```

`_source` is what lets controls add filter columns to the element later; `role` (the last argument to `add_column`) is the Sigma channel the column feeds. Then add the macro to `macros/schema.yml` (dbt checks it against the signature), a workbook in `integration_tests/` that uses it, and an assertion. `scripts/validate_against_sigma_schema.py` will check the shape against Sigma's schema for free.
