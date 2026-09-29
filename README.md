# dbt-sigma-workbook

Compose [Sigma workbooks](https://help.sigmacomputing.com/docs/manage-workbooks-as-code) from dbt macros instead of hand-writing Sigma's JSON. A workbook is a dbt model: it can `ref()` your dbt models and the tables of your [Sigma data models](https://github.com/Matts52/dbt-sigma-data-models), it is reviewed like the rest of your project, and its compiled spec lands in `manifest.json` on `dbt parse`.

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

That is a title, two filters, a KPI band, two charts and a detail table in one model.

The package never calls Sigma. It composes JSON at parse time (no warehouse connection needed) and stores it on the model's `meta`. An optional script, [`scripts/export_workbooks.py`](scripts/README.md), turns the manifest into files or pushes them to the Sigma API.

## Requirements

- dbt `>=1.6.0, <3.0.0`.
- Any adapter. The macros emit JSON, not SQL.
- To publish: a Sigma organization with [workbooks as code](https://help.sigmacomputing.com/docs/manage-workbooks-as-code) (Beta), a Sigma connection to your warehouse, and an API client for the push script.

## Installation

Not on the dbt Package Hub yet; install from git in `packages.yml`:

```yaml
packages:
  - git: "https://github.com/Matts52/dbt-sigma-workbook.git"
    revision: main            # pin a tag or commit for reproducible builds
```

To reference Sigma data model tables, also install [`Matts52/dbt-sigma-data-models`](https://github.com/Matts52/dbt-sigma-data-models) (optional).

## Setup

Set project variables in `dbt_project.yml`:

```yaml
vars:
  sigma_connection_id: "<your-sigma-connection-id>"              # Sigma connection to your warehouse
  sigma_folder_id: "<your-sigma-folder-id>"                      # folder new workbooks are created in
```

| Variable | Used for | Required |
| --- | --- | --- |
| `sigma_connection_id` | Warehouse sources. Or pass `connection_id=` per source. | When reading from the warehouse |
| `sigma_folder_id` | Where the workbook is created. Or pass `folder_id=` per workbook. | To create (not update) a workbook |
| `sigma_data_model_ids` | `{dbt_model_name: sigma_data_model_id}` for [`from_data_model`](#from-a-sigma-data-model). | When reading from data models |
| `sigma_workbook_theme` | Project-wide [theme](#theming). | No |
| `sigma_workbook_format` | `contents` (default) or `spec`; see [output format](scripts/README.md#output-format). | No |

`sigma_connection_id` and `sigma_folder_id` match `dbt-sigma-data-models`, so a project using both configures them once.

## Quickstart

1. Create `models/sigma_sales_dashboard.sql` from the example above (adjust the `ref` and columns).
2. Run `dbt parse`.
3. The workbook is at `target/manifest.json` -> `nodes` -> `model.<project>.sigma_sales_dashboard` -> `config.meta.sigma_workbook`.
4. Run `python scripts/export_workbooks.py --out sigma_workbooks/` to write it as JSON.

`materialize()` sets the model's `meta` via `config(meta=...)`, which replaces `meta` wholesale, so keep workbook models single-purpose. The body is a throwaway `select 1`; `materialize(spec, materialized='ephemeral')` avoids creating a warehouse view.

Pair the model with an `exposures:` entry so `dbt ls -s +exposure:sales_dashboard` lists everything the workbook depends on.

## Dashboard styles

`simple_dashboard` is the general-purpose shape; `simple_leaderboard` is a second one built from the same pieces. Both take the same `kpis` / `charts` / `filters` mappings and are generic: they know nothing about your data, only which fields and measures you point them at.

| Composite | Shape | Use it for |
| --- | --- | --- |
| `simple_dashboard` | title, filters, KPI band, chart pairs, detail table | a first dashboard; every part is optional |
| `simple_leaderboard` | KPI band, one ranked horizontal bar chart per dimension, optional breakdown pivot | who is on top, by any measure: teams, products, regions, accounts |

**A scorecard is a `simple_dashboard`** with a few KPIs and one or two charts, no `table_columns`, taller tiles and sparklines: `kpi_h=7` and `chart_h=12` resize them, and `trend: true` on a KPI with a `timeline` adds the sparkline.

```sql
{% set spec = sigma_workbook.simple_dashboard(
    name='Support scorecard',
    source=sigma_workbook.from_ref('tickets'),
    kpis=[
      {'value': 'CountDistinct([Ticket Id])', 'name': 'Tickets', 'timeline': 'created_at', 'trend': true},
      {'value': 'Avg([Hours To Resolve])', 'name': 'Time to resolve', 'direction': 'lower'},
    ],
    charts=[{'type': 'line', 'x': 'DateTrunc("week", [Created At])', 'y': 'Count()', 'name': 'Tickets by week'}],
    kpi_h=7,
    chart_h=12,
) %}

{% set spec = sigma_workbook.simple_leaderboard(
    name='Team standings',
    source=sigma_workbook.from_ref('scores'),
    dimensions=['team', 'region'],
    measure='Sum([Points])', measure_name='Points',
    detail_measures=['Count()'],
) %}
```

`simple_leaderboard` is a thin layer over `dashboard_page`, which is public: call it directly to build a page in the `simple_dashboard` layout and mix it with hand-built pages in a `workbook()`. A runnable leaderboard is in [`integration_tests/models/`](integration_tests/models).

## Building your own layout

`simple_dashboard` is built from the public macros; when you outgrow it, write the same thing by hand. This is a two-page version:

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

Building blocks, smallest to largest:

| Layer | Macros |
| --- | --- |
| **Sources** | `from_ref`, `warehouse_table`, `from_data_model`, `data_model`, `element` |
| **Fields** | `field`, `format_number`, `format_currency`, `format_percent`, `format_date`, `format` |
| **Elements** | `table`, `kpi`, `bar_chart`, `line_chart`, `area_chart`, `scatter_chart`, `pie_chart`, `donut_chart`, `pivot_table`, `text`, `title`, `heading`, `divider`, `container` |
| **Controls** | `list_control`, `date_range_control`, `text_control`, `number_range_control` |
| **Composites** | `row`, `kpi_row`, `dashboard_header`, `dashboard_page`, `simple_dashboard`, `simple_leaderboard` |
| **Assembly** | `page`, `workbook`, `materialize` |
| **Escape hatches** | `extend`, `raw` |

Every macro's arguments are documented in [`macros/schema.yml`](macros/schema.yml).

**Ids.** Sigma needs a stable id for every element. They are derived from an element's kind plus its `name` (or explicit `key=`), and each column from its formula, so the same source compiles to the same JSON every time. If two elements of the same kind share a name, `workbook()` fails at parse time and asks for a `key=`.

## Data sources

Every element takes a `source`; the three kinds are interchangeable.

### A dbt model or warehouse table

```sql
{% set orders = sigma_workbook.from_ref('stg_orders') %}                                  {# a dbt model #}
{% set raw    = sigma_workbook.warehouse_table(['ANALYTICS', 'PUBLIC', 'ORDERS']) %}      {# any table #}
```

`from_ref` calls `ref()`, so the workbook is downstream of the model in the DAG. The physical path is `[target.database, target.schema, <model name>]`, because a spec is composed at parse time, before other models' relations exist. For custom schemas or aliases:

```sql
{% set orders = sigma_workbook.from_ref('stg_orders', schema='analytics', identifier='orders') %}
```

### From a Sigma data model

If the data model is composed with [`dbt-sigma-data-models`](https://github.com/Matts52/dbt-sigma-data-models):

```sql
{% set sales = sigma_workbook.from_data_model('sigma_sales_model', 'orders', identifier='stg_orders') %}
```

- `sigma_sales_model` is the dbt model that calls `sigma_data_models.materialize()`; it is `ref()`ed for lineage.
- `'orders'` is the `key` of the `sigma_data_models.table(...)` call; `identifier` is its second argument (plus `database=` / `schema=` if set).
- The Sigma data model id exists only after the model is created in Sigma. Record it in `dbt_project.yml`:

  ```yaml
  vars:
    sigma_data_model_ids:
      sigma_sales_model: "<your-sigma-data-model-id>"
  ```

  Until then the id is the placeholder `unresolved:sigma_sales_model`: the project parses, and the export script refuses to push it.

### Another element

Pass a table as the source to build a chart on it (Sigma's "child element"):

```sql
{% set orders_table = sigma_workbook.table(orders, ['region', 'amount'], name='Orders') %}
{% set chart = sigma_workbook.bar_chart(orders_table, 'region', 'Sum([Amount])', name='By region') %}
```

## Fields, formulas and formats

Wherever a macro takes a column, axis or measure, write a **field**:

| You write | It means |
| --- | --- |
| `'region'` | A source column, `[Region]`. All-lowercase strings are title-cased like Sigma does (`order_date` -> `[Order Date]`); warehouse and data model columns get a `[TABLE/...]` prefix automatically. |
| `'Sum([Amount])'` | A formula, used as written. Anything containing `[`, `(`, or an uppercase letter is a formula. |
| `sigma_workbook.field('Sum([Amount])', name='Revenue', format=sigma_workbook.format_currency())` | A formula with a display name and/or number format. |

Inside a formula, refer to columns unqualified (`Sum([Amount])`). The package adds the qualified passthrough column (`[stg_orders/Amount]`), which is what Sigma writes when it exports a workbook. A column can feed only one channel of an element, so a measure used twice (a KPI's value and comparison) becomes two columns automatically.

Formulas use [Sigma's formula syntax](https://help.sigmacomputing.com/docs/formula-reference) and are not parsed here; an invalid one is only caught when Sigma validates the workbook (`--push --dry-run`).

Formats: `format_number(decimals)`, `format_currency(decimals, symbol)`, `format_percent(decimals)`, `format_date(pattern)`; `format(kind, options)` accepts Sigma's documented option keys and rejects the rest.

## Controls (filters)

A control takes a list of `(element, field)` targets: the elements it filters and the column to filter on.

```sql
{% set region_filter = sigma_workbook.list_control('Region', targets=[(detail, 'region'), (by_region, 'region')]) %}
{% set date_filter   = sigma_workbook.date_range_control('Order date', targets=[(detail, 'order_date')]) %}
```

- A target column missing from an element is added (a table's visible columns are unchanged).
- A list control gets its values from its first target. Others: `text_control`, `number_range_control`.
- Build controls **after** the elements they target, and list every element to filter; siblings are not filtered automatically. `simple_dashboard` does this for you.
- A control's `controlId` shares Sigma's namespace with column names. It defaults to the lowercase dashed name plus `-control` (`Region` -> `region-control`). Pass `control_id=` to override; `workbook()` rejects one that collides with a column name.

## Layout

Elements sit on Sigma's 24-column grid, placed left to right in the order listed and wrapping when a row fills. You never write the layout XML.

| Element | Default `w` x `h` |
| --- | --- |
| `table`, `pivot_table`, `title`, `text`, `divider` | 24 x 14 / 14 / 3 / 2 / 1 |
| `bar_chart`, `line_chart`, `area_chart`, `scatter_chart` | 12 x 14 |
| `pie_chart`, `donut_chart` | 8 x 14 |
| `kpi` | 6 x 5 (`kpi_row` resizes to fill the width) |
| controls | 6 x 2 |

- `row([a, b, c], 'key')` puts elements side by side, sharing the 24 columns.
- `container([...], key='key')` groups elements on their own grid (invisible unless `card=true`).
- Every element macro accepts `w=` and `h=`.

Placement is flow-only; there is no absolute x/y yet.

## Theming

Defaults follow Sigma's look (Sigma blue `#1A70F1` on neutral grays). Three levels, each deep-merged over the last:

1. **Package defaults**: `sigma_workbook.default_theme()`.
2. **Project**, in `dbt_project.yml`:

   ```yaml
   vars:
     sigma_workbook_theme:
       colors:
         primary: "#7008e7"        # single-series charts, sparklines, the theme highlight
         success: "#008236"
       categorical: ["#7008e7", "#1A70F1", "#00786f"]   # or a Sigma palette name, e.g. "superbloom" (default)
       fonts: {text: "Inter", data: "Inter"}
       cards: true                # white bordered cards around charts/tables/KPIs
   ```

3. **Workbook**: `sigma_workbook.workbook(..., theme={'colors': {'primary': '#7008e7'}})`.

Color tokens: `primary`, `text`, `body`, `muted`, `hairline`, `canvas`, `surface`, `success`, `warning`, `danger`. Other keys: `name` (`Light`/`Dark`/`Surface`), `categorical`, `sequential`, `diverging`, `fonts`, `page_width` (`full`/`large`/`medium`), `cards` (project level only).

The theme is written to the workbook's `settings.theme`, and element colors use the same tokens, so a workbook-level `theme=` recolors them too. Use tokens in your own macros with `sigma_workbook.color('primary')`.

## Macro reference

Full signatures are in [`macros/schema.yml`](macros/schema.yml). Highlights:

| Macro | Notes |
| --- | --- |
| `workbook(name, pages, theme, folder_id, workbook_id, description, output)` | Validates and assembles the spec. |
| `page(name, elements)` | `elements` may mix elements and lists of elements. |
| `materialize(spec, materialized='view')` | Attaches the spec to the model. |
| `simple_dashboard(name, source, kpis, charts, filters, table_columns, kpi_h, chart_h, ...)` | A whole dashboard from data. |
| `simple_leaderboard(name, source, dimensions, measure, kpis, detail_measures, filters, ...)` | Ranked horizontal bars per dimension, plus a breakdown pivot. |
| `dashboard_page(name, source, kpis, charts, filters, table_columns, extras, ...)` | One such page, for mixing into your own `workbook()`. |

Elements all take `source`, `name` / `key`, `w`, `h`, `style`, plus:

| Macro | Key arguments |
| --- | --- |
| `table` | `columns`, `sort=[('field','desc')]` |
| `kpi` | `value`, `format`, `compare_to`, `timeline` + `period`, `trend`, `direction` |
| `bar_chart` | `x`, `y` (or a list), `color`, `sort_by`, `sort_direction`, `stacking`, `labels`, `horizontal`, `legend` |
| `line_chart` / `area_chart` | as `bar_chart`, minus `horizontal` |
| `scatter_chart` | `x`, `y`, `color`, `size` |
| `pie_chart` / `donut_chart` | `category`, `value`; donut adds `hole_value` |
| `pivot_table` | `values`, `rows`, `cols` |
| `text`, `title`, `heading`, `divider` | Non-data elements. |
| `container` | `elements`, `card` |

## Escape hatches

Two macros keep Sigma's many unmodeled options reachable:

```sql
{# add raw Sigma options to an element built by a normal macro (nested mappings merge) #}
{% set chart = sigma_workbook.extend(
    sigma_workbook.bar_chart(orders, 'region', 'Count()', name='Orders'),
    {'barStyle': {'cornerRadius': 'round'}, 'gap': {'width': 'small'}}) %}

{# an element kind with no macro yet (button, image, embed, gauge-chart, combo-chart, ...) #}
{% set button = sigma_workbook.raw('button', 'open_sigma', {'text': 'Open Sigma'}, w=4, h=2) %}
```

Both take part in layout, id checks and private-key stripping. Their raw properties are not checked by the package; `scripts/validate_against_sigma_schema.py` checks them against Sigma's published schema.

## Limitations

An initial version aimed at dashboards. Coverage, unmodeled elements and known limits are in [`LIMITATIONS.md`](LIMITATIONS.md).

## Development

```bash
python -m venv .venv && . .venv/bin/activate
pip install -r ci/requirements-dbt1.txt
bash scripts/run_integration_tests_duckdb.sh   # the whole suite; no credentials needed
python -m unittest scripts/test_export_workbooks.py
```

The [integration suite](integration_tests/README.md) builds workbooks of every shape, checks each compiled spec, validates it against Sigma's request schema, and confirms that 28 kinds of invalid input are rejected. Design notes and a critique of the abstraction are in [`docs/design.md`](docs/design.md). Contributions are welcome; see [`CONTRIBUTING.md`](CONTRIBUTING.md).

## License

MIT
