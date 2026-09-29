# dbt-sigma-workbook

Compose [Sigma workbooks](https://help.sigmacomputing.com/docs/manage-workbooks-as-code) from dbt macros instead of hand-writing Sigma's JSON. A workbook becomes a dbt model: it can `ref()` your dbt models and the tables of your [Sigma data models](https://github.com/Matts52/dbt-sigma-data-models), it is version-controlled and reviewed like the rest of your project, and its compiled spec lands in `manifest.json` on `dbt parse`.

```sql
-- models/sigma_sales_dashboard.sql
{% set spec = sigma_workbook.simple_dashboard(
    name='Sales at a glance',
    source=sigma_workbook.from_ref('stg_orders'),
    kpis=[
      {'value': 'Sum([Amount])', 'name': 'Revenue', 'format': sigma_workbook.format_currency()},
      {'value': 'Count()', 'name': 'Orders'},
    ],
    charts=[
      {'type': 'bar',   'x': 'region',  'y': 'Sum([Amount])', 'name': 'Revenue by region'},
      {'type': 'donut', 'category': 'segment', 'value': 'Sum([Amount])', 'name': 'Revenue by segment'},
    ],
    filters=[
      {'type': 'list', 'name': 'Region', 'column': 'region'},
      {'type': 'date_range', 'name': 'Order date', 'column': 'order_date'},
    ],
    table_columns=['order_id', 'order_date', 'region', 'segment', 'amount'],
) %}

{{ sigma_workbook.materialize(spec) }}

select 1
```

That is a title, two filters, a KPI band, two charts and a detail table, all styled with Sigma's blue and wired together, in one model. For several detail tables, use `tables` instead of (or as well as) `table_columns`:

```sql
    tables=[
      {'name': 'Orders',    'columns': ['order_id', 'order_date', 'region', 'amount'], 'sort': [('order_date', 'desc')]},
      {'name': 'By region', 'columns': ['region', 'segment', 'amount']},
    ],
```

Every filter applies to every table, as it does to the KPIs and charts.

**What this package does not do:** it never calls Sigma. It composes JSON at parse time (no warehouse connection needed) and stores it on the model's `meta`. A small optional script, [`scripts/export_workbooks.py`](#getting-the-workbook-into-sigma), turns the manifest into files or pushes them to the Sigma API.

## Contents

- [Requirements](#requirements)
- [Installation](#installation)
- [Setup](#setup)
- [Quickstart](#quickstart)
- [Building your own layout](#building-your-own-layout)
- [Data sources](#data-sources)
- [Fields, formulas and formats](#fields-formulas-and-formats)
- [Controls (filters)](#controls-filters)
- [Layout](#layout)
- [Theming](#theming)
- [Getting the workbook into Sigma](#getting-the-workbook-into-sigma)
- [Macro reference](#macro-reference)
- [Escape hatches](#escape-hatches)
- [Coverage and known limits](#coverage-and-known-limits)
- [Development](#development)

## Requirements

- dbt `>=1.6.0, <3.0.0`. **dbt 1.x and dbt 2.x are both tested in CI** (see [dbt 2 support](#dbt-2-support)).
- Any adapter. The macros emit JSON and no SQL, so nothing is adapter-specific; CI runs on DuckDB.
- To publish: a Sigma organization with [workbooks as code](https://help.sigmacomputing.com/docs/manage-workbooks-as-code) (Beta), a Sigma connection to the warehouse your models build into, and an API client if you use the push script.

## Installation

Add the package to `packages.yml`. It is not on the dbt Hub yet, so install it from git:

```yaml
packages:
  - git: "https://github.com/mattsenicksigma/dbt-sigma-workbook.git"
    revision: main            # pin a tag or commit for reproducible builds
```

The repository is private, so `dbt deps` needs credentials. In CI, use a token in the URL:

```yaml
  - git: "https://{{ env_var('DBT_ENV_SECRET_GIT_CREDENTIAL') }}@github.com/mattsenicksigma/dbt-sigma-workbook.git"
    revision: main
```

Then run `dbt deps`. To reference tables from Sigma data models, also install [`Matts52/dbt-sigma-data-models`](https://github.com/Matts52/dbt-sigma-data-models) (optional; see [Data models](#from-a-sigma-data-model)).

## Setup

Set two project variables in `dbt_project.yml`:

```yaml
vars:
  sigma_connection_id: "17edf046-9636-4d9b-a13f-d034bec2d600"   # Sigma connection to your warehouse
  sigma_folder_id: "e7c79c61-94d4-458e-ab4c-f581a4c04a4c"        # folder new workbooks are created in
```

| Variable | Used for | Required |
| --- | --- | --- |
| `sigma_connection_id` | Warehouse sources (`from_ref`, `warehouse_table`). Can also be passed per source with `connection_id=`. | When a workbook reads from the warehouse |
| `sigma_folder_id` | Where the workbook is created. Can also be passed per workbook with `folder_id=`. | To create a workbook (not to update one) |
| `sigma_data_model_ids` | `{dbt_model_name: sigma_data_model_id}` for [`from_data_model`](#from-a-sigma-data-model). | When reading from data models |
| `sigma_workbook_theme` | Project-wide [theme](#theming). | No |

The names `sigma_connection_id` and `sigma_folder_id` match those used by `dbt-sigma-data-models`, so a project using both configures them once.

## Quickstart

A workbook is a dbt model with two things in it: a `sigma_workbook.*` expression that builds the spec, and `sigma_workbook.materialize(spec)` that attaches it to the model.

1. Create `models/sigma_sales_dashboard.sql` with the example at the top of this page (adjust the `ref` and column names to your data).
2. Run `dbt parse`.
3. Your workbook is at `target/manifest.json` -> `nodes` -> `model.<project>.sigma_sales_dashboard` -> `config.meta.sigma_workbook`.
4. Run `python scripts/export_workbooks.py --out sigma_workbooks/` to write it as JSON (see [Getting the workbook into Sigma](#getting-the-workbook-into-sigma)).

`materialize()` sets the model's `meta` through `config(meta=...)`, which replaces `meta` wholesale. Keep workbook models single-purpose. The model body is a throwaway `select 1`; `materialize(spec, materialized='ephemeral')` avoids creating a view in your warehouse.

Pair the model with an `exposures:` entry to select everything a workbook depends on:

```yaml
exposures:
  - name: sales_dashboard
    type: dashboard
    owner: {name: Data Team, email: data@example.com}
    depends_on:
      - ref('stg_orders')
      - ref('sigma_sales_dashboard')
```

`dbt ls -s +exposure:sales_dashboard` then lists the full upstream lineage.

## Building your own layout

`simple_dashboard` is itself built from the public macros; when you outgrow it, write the same thing by hand and change what you like. This is the same workbook with two pages:

```sql
{% set orders = sigma_workbook.from_ref('stg_orders') %}

{# elements are built first, so controls and other elements can refer to them #}
{% set detail = sigma_workbook.table(orders,
    ['order_id', 'order_date', 'region',
     sigma_workbook.field('[Amount]', name='Revenue', format=sigma_workbook.format_currency(2))],
    name='Orders', sort=[('order_date', 'desc')]) %}

{% set revenue = sigma_workbook.kpi(orders, 'Sum([Amount])', name='Revenue',
    format=sigma_workbook.format_currency(), compare_to='Sum([Target Amount])') %}
{% set monthly = sigma_workbook.kpi(orders, 'CountDistinct([Order Id])', name='Orders',
    timeline='order_date', period='month', trend=true) %}

{% set by_region = sigma_workbook.bar_chart(orders, 'region', 'Sum([Amount])', name='Revenue by region') %}
{% set by_month  = sigma_workbook.line_chart(orders, 'DateTrunc("month", [Order Date])', 'Sum([Amount])',
    color='segment', name='Revenue by month', sort_by='x') %}

{% set region_filter = sigma_workbook.list_control('Region',
    targets=[(detail, 'region'), (revenue, 'region'), (by_region, 'region'), (by_month, 'region')]) %}

{% set spec = sigma_workbook.workbook(
    name='Sales dashboard',
    pages=[
      sigma_workbook.page('Overview', [
        sigma_workbook.dashboard_header('Sales overview', 'Bookings against plan', [region_filter]),
        sigma_workbook.kpi_row([revenue, monthly]),
        sigma_workbook.row([by_region, by_month], 'charts'),
      ]),
      sigma_workbook.page('Detail', [detail]),
    ],
) %}

{{ sigma_workbook.materialize(spec) }}

select 1
```

The building blocks, from smallest to largest:

| Layer | Macros | Purpose |
| --- | --- | --- |
| **Sources** | `from_ref`, `warehouse_table`, `from_data_model`, `data_model`, `element` | Where an element's rows come from. |
| **Fields** | `field`, `format_number`, `format_currency`, `format_percent`, `format_date`, `format` | What is plotted / shown, and how it is formatted. |
| **Elements** | `table`, `kpi`, `bar_chart`, `line_chart`, `area_chart`, `scatter_chart`, `pie_chart`, `donut_chart`, `pivot_table`, `text`, `title`, `heading`, `divider`, `container` | One thing on the page. |
| **Controls** | `list_control`, `date_range_control`, `text_control`, `number_range_control` | Filters that target elements. |
| **Composites** | `row`, `kpi_row`, `dashboard_header`, `simple_dashboard` | Arrangements built only from the layers above. |
| **Assembly** | `page`, `workbook`, `materialize` | Pages -> a validated spec -> the model's `meta`. |
| **Escape hatches** | `extend`, `raw` | Anything Sigma supports that a macro does not. |

Every macro's arguments are documented in [`macros/schema.yml`](macros/schema.yml).

### Identity and ids

Sigma needs a stable id for every element. The package derives them from what you write: an element's kind plus its `name` (or an explicit `key=`), and each column from its formula. The same source compiles to the same JSON every time, so re-running a deploy is idempotent and diffs are meaningful. If two elements of the same kind share a name (two bar charts called "Revenue"), `workbook()` fails at parse time and asks for a `key=`.

## Data sources

Every element takes a `source`. There are three kinds; all are interchangeable anywhere `source` is accepted.

### A dbt model or warehouse table

```sql
{% set orders = sigma_workbook.from_ref('stg_orders') %}                                  {# a dbt model #}
{% set raw    = sigma_workbook.warehouse_table(['ANALYTICS', 'PUBLIC', 'ORDERS']) %}      {# any table #}
```

`from_ref` calls `ref()`, so the workbook model is downstream of the model in the DAG and appears in `dbt docs` lineage. The physical path is `[target.database, target.schema, <model name>]`. It cannot be read back from `ref()`, because a workbook spec is composed at *parse* time, when other models' relations do not exist yet. If your models build into a custom schema or use an alias, say so:

```sql
{% set orders = sigma_workbook.from_ref('stg_orders', schema='analytics', identifier='orders') %}
```

### From a Sigma data model

Workbooks can read from a table inside a Sigma data model, so metrics and column definitions live in one governed place. If the data model is composed with [`dbt-sigma-data-models`](https://github.com/Matts52/dbt-sigma-data-models):

```sql
{% set sales = sigma_workbook.from_data_model('sigma_sales_model', 'orders', identifier='stg_orders') %}
```

- `sigma_sales_model` is the dbt model that calls `sigma_data_models.materialize()`. It is `ref()`ed for lineage.
- `'orders'` is the `key` given to `sigma_data_models.table('orders', 'stg_orders', ...)`; `identifier` is that call's second argument (and `database=` / `schema=` too, if it set them).
- The Sigma **data model id** only exists after the data model has been created in Sigma. Record it in `dbt_project.yml`:

  ```yaml
  vars:
    sigma_data_model_ids:
      sigma_sales_model: "5c1f0e57-3e0a-4b1c-9f6f-0a5d6c7b8e9f"
  ```

  Until then the id is the placeholder `unresolved:sigma_sales_model`: your project still parses, and the export script refuses to push it.

The table's element id is derived exactly as `sigma_data_models` derives it, so the two packages agree with no shared state. CI checks that the ids match against the real package.

### Another element

A chart can be built on a table in the same workbook (Sigma's "child element"): pass the table as the source.

```sql
{% set orders_table = sigma_workbook.table(orders, ['region', 'amount'], name='Orders') %}
{% set chart = sigma_workbook.bar_chart(orders_table, 'region', 'Sum([Amount])', name='By region') %}
```

## Fields, formulas and formats

Wherever a macro takes a column, axis or measure, write it as a **field**:

| You write | It means |
| --- | --- |
| `'region'` | A source column: `[Region]`. All-lowercase strings are title-cased the way Sigma title-cases warehouse columns (`order_date` -> `[Order Date]`); columns read from a warehouse or data model table are prefixed `[TABLE/Order Date]` automatically. |
| `'Sum([Amount])'` | A formula, used as written. Anything containing `[`, `(`, or an uppercase letter is treated as a formula. |
| `sigma_workbook.field('Sum([Amount])', name='Revenue', format=sigma_workbook.format_currency())` | A formula with a display name and/or number format. |

Inside a formula, refer to columns unqualified (`Sum([Amount])`). The package then adds the qualified passthrough column (`[stg_orders/Amount]`) to the element, which is exactly what Sigma itself writes when it exports a workbook. A column can feed only one channel of an element, so the same measure used twice (a KPI's value and its comparison, a donut's slices and its hole) becomes two columns automatically.

Formulas use [Sigma's formula syntax](https://help.sigmacomputing.com/docs/formula-reference). The package does not parse them, so a formula Sigma cannot evaluate is only caught when Sigma validates the workbook (`--push --dry-run`).

Formats: `format_number(decimals)`, `format_currency(decimals, symbol)`, `format_percent(decimals)`, `format_date(pattern)`; the generic `format(kind, options)` accepts Sigma's documented option keys and rejects the rest.

## Controls (filters)

A control is built from a list of `(element, field)` targets: the elements it filters and the column to filter on.

```sql
{% set region_filter = sigma_workbook.list_control('Region', targets=[(detail, 'region'), (by_region, 'region')]) %}
{% set date_filter   = sigma_workbook.date_range_control('Order date', targets=[(detail, 'order_date')]) %}
```

If a target element does not have the column yet it is added (a table's visible column `order` is untouched, so the table looks the same). A list control gets its selectable values from its first target. Other controls: `text_control`, `number_range_control`. A control's `controlId` is how Sigma formulas refer to it, in the same namespace as column names, so it defaults to the lowercase dash-separated name plus `-control` (`Region` -> `region-control`): a control called `Duration` next to a formula using `[Duration]` is a circular dependency in Sigma. Pass `control_id=` to choose your own; `workbook()` refuses one that collides with a column name.

Build controls **after** the elements they target, and list every element a control should filter: filtering one element does not filter its siblings automatically. `simple_dashboard` does this wiring for you.

## Layout

Sigma places elements on a 24-column grid using an XML `layout` string. You do not write it: elements are placed left to right in the order you list them, wrapping to a new row when 24 columns fill, and each element has a default footprint (`w=` width in columns, `h=` height in rows):

| Element | Default `w` x `h` |
| --- | --- |
| `table`, `pivot_table`, `title`, `text`, `divider` | 24 x 14 / 14 / 3 / 2 / 1 |
| `bar_chart`, `line_chart`, `area_chart`, `scatter_chart` | 12 x 14 |
| `pie_chart`, `donut_chart` | 8 x 14 |
| `kpi` | 6 x 5 (`kpi_row` resizes to fill the width) |
| controls | 6 x 2 |

- `sigma_workbook.row([a, b, c], 'key')` puts elements side by side, sharing the 24 columns evenly.
- `sigma_workbook.container([...], key='key')` groups elements on their own grid (invisible unless `card=true`).
- Every element macro accepts `w=` and `h=` to override the footprint.

Placement is flow-only: there is no absolute x/y positioning yet (see [limits](#coverage-and-known-limits)).

## Theming

Colors, fonts and palettes default to Sigma's look (Sigma blue `#1A70F1` as the primary color on a neutral gray scale) and are configurable at three levels. Each level is deep-merged over the previous one, so you set only what you want to change:

1. **Package defaults**: `sigma_workbook.default_theme()`.
2. **Project**, in `dbt_project.yml`:

   ```yaml
   vars:
     sigma_workbook_theme:
       colors:
         primary: "#7008e7"        # every accent: single-series charts, sparklines, the theme highlight
         success: "#008236"
       categorical: ["#7008e7", "#1A70F1", "#00786f"]   # or a Sigma palette name, e.g. "superbloom" (default)
       fonts: {text: "Inter", data: "Inter"}
       cards: true                # white bordered cards around charts/tables/KPIs
   ```

3. **Workbook**, for one workbook only: `sigma_workbook.workbook(..., theme={'colors': {'primary': '#7008e7'}})`.

Tokens (`colors`): `primary`, `text`, `body`, `muted`, `hairline`, `canvas`, `surface`, `success`, `warning`, `danger`. Other theme keys: `name` (`Light`/`Dark`/`Surface`), `categorical`, `sequential`, `diverging`, `fonts`, `page_width` (`full`/`large`/`medium`), `cards`.

The theme is written to the workbook's Sigma `settings.theme`, so anything you add in Sigma's UI afterwards inherits it. Element colors (a chart's series color, a KPI's good/bad colors) refer to the same tokens, so a workbook-level `theme=` override recolors them too. Use the tokens in your own macros with `sigma_workbook.color('primary')`. `cards` is read at project level only.

## Getting the workbook into Sigma

`dbt parse` puts each workbook's request body at `manifest.json` -> `nodes.<model>.config.meta.sigma_workbook`. [`scripts/export_workbooks.py`](scripts/export_workbooks.py) is a dependency-free Python script (3.9+) that takes it from there:

```bash
dbt parse
python scripts/export_workbooks.py --out sigma_workbooks/         # write one <model>.json per workbook
python scripts/export_workbooks.py --check                        # validate offline; non-zero on problems
python scripts/export_workbooks.py --select sigma_sales_dashboard --out sigma_workbooks/

export SIGMA_API_URL=https://api.sigmacomputing.com               # your region's API host
export SIGMA_CLIENT_ID=... SIGMA_CLIENT_SECRET=...
python scripts/export_workbooks.py --push --dry-run               # ask Sigma to validate, create nothing
python scripts/export_workbooks.py --push                         # create / update the workbooks
```

`--check` fails on: an unresolved data model id, a missing `folderId`, duplicate element ids, or a warehouse source without a connection.

To **update** a workbook instead of creating another, pass its id: `sigma_workbook.workbook(..., workbook_id='<id>')`. The script then sends `PUT /v2/workbooks/{id}/contents`. Note that Sigma creates a new version of that workbook; hand edits made in Sigma to the same elements are replaced.

You can also skip the script: the exported JSON is the exact body of [`POST /v2/workbooks`](https://help.sigmacomputing.com/reference/createworkbook), so `curl`, `sigcli` or your orchestrator can send it. (The deprecated `/v2/workbooks/spec` endpoints and their nested `pages[].elements` shape are not supported.)

## Macro reference

Every public macro, with each argument's type and meaning, is documented in [`macros/schema.yml`](macros/schema.yml); dbt checks that file against the macro signatures. The tables under [Building your own layout](#building-your-own-layout) group the macros by layer.

## Escape hatches

Sigma's schema has hundreds of options beyond what these macros expose. Two macros keep that from ever being a dead end:

```sql
{# add raw Sigma options to an element built by a normal macro (nested mappings merge) #}
{% set chart = sigma_workbook.extend(
    sigma_workbook.bar_chart(orders, 'region', 'Count()', name='Orders'),
    {'barStyle': {'cornerRadius': 'round'}, 'gap': {'width': 'small'}}) %}

{# an element kind with no macro yet (button, image, embed, gauge-chart, combo-chart, ...) #}
{% set button = sigma_workbook.raw('button', 'open_sigma', {'text': 'Open Sigma'}, w=4, h=2) %}
```

Both take part in layout, id checks and private-key stripping like any other element. Their raw properties are not checked by the package; `scripts/validate_against_sigma_schema.py` checks them against Sigma's published schema.

## Coverage and known limits

This is an initial version aimed at dashboards. The honest list:

- **Validated by Sigma, not yet rendered.** Beyond CI (which checks every workbook against the request schema in Sigma's public OpenAPI), the output was checked with `POST /v2/workbooks` and `dryRun: true` against a real Sigma organization: a warehouse-table workbook using every modeled element type, a workbook reading a real data model, and child elements. Sigma's dry run parses formulas, resolves `[TABLE/Column]` references, and checks sources, connections and layout. It does not create the workbook, so what it cannot tell you is how the result *looks* or whether an unqualified `[Column]` in a formula resolves (the package follows Sigma's own export convention, see [Fields](#fields-formulas-and-formats)). Workbooks as code is a Sigma Beta feature and its API can change; `--push --dry-run` is the first thing to run against your own organization, and CI does not (it has no Sigma credentials).
- **Modeled elements**: table, KPI, bar / line / area / scatter / pie / donut charts, pivot table, text, divider, container, list / date-range / text / number-range controls. Not modeled (use [`raw`](#escape-hatches)): maps, combo / waterfall / funnel / gauge / sankey / treemap / box charts, input tables, buttons and actions, forms, images, embeds, tabbed containers, modals and drawers, conditional formatting, reference marks, trellis.
- **Controls target any data element**, but Sigma's documented filter target is a table. Filtering a chart or KPI directly is emitted the same way; confirm with `--dry-run`.
- **Layout is flow-only**: left to right, wrapping. No absolute x/y placement or spanning rows.
- **Source paths use `target.database` / `target.schema`** unless overridden (see [Data sources](#a-dbt-model-or-warehouse-table)).
- **Formulas are strings.** The package cannot check that a formula is valid for your data.
- **Workbook-level `theme=`** changes colors, palettes, fonts and page width; `cards` is project-level.
- One `sigma_workbook` per model. Models that set other `meta` keys lose them to `materialize()`.

## dbt 2 support

- `require-dbt-version: [">=1.6.0", "<3.0.0"]`, so dbt 2.x installs it.
- CI runs the entire integration suite on **both** dbt 1.12 and dbt 2.0 (the Rust engine published as `dbt-core` 2.x) on DuckDB.
- `macros/schema.yml` uses the argument types dbt 1.10+ / 2.x validate (`list[any]`, `dict[string,any]`, `bool`, `int`), and CI runs `dbt parse --warn-error` with `validate_macro_args: true`, so an argument documented under the wrong name fails the build.
- No `**kwargs`, no `adapter.dispatch`, no reliance on `execute`; every macro is pure Jinja that runs at parse time.
- Custom config lives under `meta`, the only place dbt 2 accepts non-standard keys on a model.

## Development

```bash
python -m venv .venv && . .venv/bin/activate
pip install -r ci/requirements-dbt1.txt        # or ci/requirements-dbt2.txt for dbt 2.x
bash scripts/run_integration_tests_duckdb.sh   # the whole suite; no credentials needed
python -m unittest scripts/test_export_workbooks.py
```

The integration suite (`integration_tests/README.md` describes what it checks) seeds a small dataset, builds workbooks of every shape, checks each compiled spec's structure, cross-references, layout, theme and data-model interop, validates it against Sigma's request schema, exports it, and confirms that 29 kinds of invalid input are rejected. Design notes and a critique of the abstraction are in [`docs/design.md`](docs/design.md).

## License

MIT
