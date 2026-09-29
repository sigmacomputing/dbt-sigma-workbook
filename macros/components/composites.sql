{# Composites: reusable arrangements built only from the primitives in elements/. Nothing here knows a
   Sigma field name - each one calls the same public element macros a user would, which is what
   keeps the library composable: if a composite doesn't fit, copy its body and change it. #}


{# Splits `n` items across the 24-column grid as evenly as possible; leftover columns go to the
   leading items, so 5 items -> 5,5,5,5,4 and 4 items -> 6,6,6,6 (the widths Sigma's own build
   plugin uses for KPI bands). #}
{% macro even_widths(n, columns=24) %}
{% set base = columns // n %}
{% set extra = columns % n %}
{% set widths = [] %}
{% for i in range(n) %}
  {% do widths.append(base + (1 if i < extra else 0)) %}
{% endfor %}
{% do return(widths) %}
{% endmacro %}


{# A container whose children share the width evenly, all resized to a common height when `h` is
   given: the building block for KPI bands, chart rows and control strips. #}
{% macro row(elements, key, h=none) %}
{% set widths = sigma_workbook.even_widths(elements | length) %}
{% for el in elements %}
  {% do el.update({"_w": widths[loop.index0]}) %}
  {% if h is not none %}
    {% do el.update({"_h": h}) %}
  {% endif %}
{% endfor %}
{% do return(sigma_workbook.container(elements, key=key)) %}
{% endmacro %}


{# A band of KPI tiles, sized to fill the page width. #}
{% macro kpi_row(kpis, key='kpis') %}
{% do return(sigma_workbook.row(kpis, key, h=5)) %}
{% endmacro %}


{# The top of a dashboard: a title, an optional subtitle, and (if given) a strip of controls.
   Returns a list, which `page()` flattens. #}
{% macro dashboard_header(title, subtitle=none, controls=[]) %}
{% set parts = [sigma_workbook.title(title, subtitle)] %}
{% if controls %}
  {% do parts.append(sigma_workbook.container(controls, key='filters:' ~ title)) %}
{% endif %}
{% do return(parts) %}
{% endmacro %}


{# One chart described as data, for `simple_dashboard`. Dispatches on `type`; the keys are the
   arguments of the matching chart macro (x/y for bar, line, area and scatter; category/value for
   pie and donut), plus `name`, `color`, `stacking`, `sort_by` and `key`. #}
{% macro chart_from_spec(source, spec) %}
{% set t = spec.get('type') %}
{% if t == 'bar' %}
  {% do return(sigma_workbook.bar_chart(source, spec['x'], spec['y'], color=spec.get('color'), name=spec.get('name'), key=spec.get('key'), stacking=spec.get('stacking'), sort_by=spec.get('sort_by', 'y'), labels=spec.get('labels', false))) %}
{% elif t == 'line' %}
  {% do return(sigma_workbook.line_chart(source, spec['x'], spec['y'], color=spec.get('color'), name=spec.get('name'), key=spec.get('key'), sort_by=spec.get('sort_by'))) %}
{% elif t == 'area' %}
  {% do return(sigma_workbook.area_chart(source, spec['x'], spec['y'], color=spec.get('color'), name=spec.get('name'), key=spec.get('key'), stacking=spec.get('stacking'), sort_by=spec.get('sort_by'))) %}
{% elif t == 'pie' %}
  {% do return(sigma_workbook.pie_chart(source, spec['category'], spec['value'], name=spec.get('name'), key=spec.get('key'))) %}
{% elif t == 'donut' %}
  {% do return(sigma_workbook.donut_chart(source, spec['category'], spec['value'], name=spec.get('name'), key=spec.get('key'))) %}
{% elif t == 'scatter' %}
  {% do return(sigma_workbook.scatter_chart(source, spec['x'], spec['y'], color=spec.get('color'), size=spec.get('size'), name=spec.get('name'), key=spec.get('key'))) %}
{% endif %}
{% do sigma_workbook.fail('simple_dashboard', "unknown chart type '" ~ t ~ "' - must be one of bar, line, area, pie, donut, scatter.") %}
{% endmacro %}


{# A complete one-page dashboard from data alone:

     title -> filters -> KPI band -> chart rows -> detail table(s)

   `kpis` is a list of {value, name, format, compare_to, timeline, period, trend}; `charts` a list of
   chart specs (see chart_from_spec); `filters` a list of {type, name, column} with type one of
   list, date_range, text. Detail tables come from `tables` - a list of `{name, columns, sort}`
   mappings, shown in order under the charts - or, for the common single-table case, from
   `table_columns` (a table called `table_name`, default Detail). Give both and the `table_columns`
   table comes first. Filters are wired to every KPI, chart and table, so one control narrows the
   whole page.

   Every piece is just the primitives from elements/ - `simple_dashboard` is the shortest path to
   something on screen, and a template for writing your own layout. #}
{% macro simple_dashboard(name, source, kpis=[], charts=[], filters=[], table_columns=none, subtitle=none, theme={}, table_name='Detail', tables=[]) %}
{% set source = sigma_workbook.resolve_source(source, 'simple_dashboard') %}
{% if not (kpis or charts or table_columns or tables) %}
  {% do sigma_workbook.fail('simple_dashboard', "give at least one of kpis, charts, table_columns or tables.") %}
{% endif %}

{% set tiles = [] %}
{% for k in kpis %}
  {% do tiles.append(sigma_workbook.kpi(
    source, k['value'], name=k.get('name'), format=k.get('format'),
    compare_to=k.get('compare_to'), timeline=k.get('timeline'), period=k.get('period', 'month'),
    trend=k.get('trend', false)
  )) %}
{% endfor %}

{% set built = [] %}
{% for c in charts %}
  {% do built.append(sigma_workbook.chart_from_spec(source, c)) %}
{% endfor %}

{% set details = [] %}
{% if table_columns %}
  {% do details.append(sigma_workbook.table(source, table_columns, name=table_name, key='detail')) %}
{% endif %}
{% for t in tables %}
  {% if t is not mapping or not t.get('columns') %}
    {% do sigma_workbook.fail('simple_dashboard', "each entry in tables must be {name, columns[, sort, key]} with columns, got " ~ t) %}
  {% endif %}
  {% do details.append(sigma_workbook.table(source, t['columns'], name=t.get('name'), key=t.get('key'), sort=t.get('sort', []))) %}
{% endfor %}

{# Controls are built last so they can be wired to every element above. #}
{% set targets_of = tiles + built + details %}
{% set controls = [] %}
{% for f in filters %}
  {% set kind = f.get('type', 'list') %}
  {% set targets = [] %}
  {% for el in targets_of %}
    {% do targets.append((el, f['column'])) %}
  {% endfor %}
  {% if kind == 'list' %}
    {% do controls.append(sigma_workbook.list_control(f['name'], targets=targets)) %}
  {% elif kind == 'date_range' %}
    {% do controls.append(sigma_workbook.date_range_control(f['name'], targets=targets)) %}
  {% elif kind == 'text' %}
    {% do controls.append(sigma_workbook.text_control(f['name'], targets=targets)) %}
  {% else %}
    {% do sigma_workbook.fail('simple_dashboard', "unknown filter type '" ~ kind ~ "' - must be list, date_range or text.") %}
  {% endif %}
{% endfor %}

{% set body = sigma_workbook.dashboard_header(name, subtitle, controls) %}
{% if tiles %}
  {% do body.append(sigma_workbook.kpi_row(tiles)) %}
{% endif %}
{% for pair_start in range(0, built | length, 2) %}
  {% do body.append(sigma_workbook.row(built[pair_start:pair_start + 2], 'charts:' ~ pair_start)) %}
{% endfor %}
{% for detail in details %}
  {% do body.append(detail) %}
{% endfor %}

{% do return(sigma_workbook.workbook(name, [sigma_workbook.page(name, body)], theme=theme)) %}
{% endmacro %}
