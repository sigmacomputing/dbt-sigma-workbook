{# Composites: reusable arrangements built only from the primitives in elements/. Nothing here knows a
   Sigma field name - each one calls the same public element macros a user would, which is what
   keeps the library composable: if a composite doesn't fit, copy its body and change it. #}


{# Splits `n` items across the 24-column grid as evenly as possible; leftover columns go to the
   leading items, so 5 items -> 5,5,5,5,4 and 4 items -> 6,6,6,6. #}
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


{# One KPI described as data: a {value, name, format, compare_to, timeline, period, trend, direction,
   key} mapping, the arguments of `kpi`. #}
{% macro kpi_from_spec(source, spec) %}
{% do return(sigma_workbook.kpi(
  source, spec['value'], name=spec.get('name'), key=spec.get('key'), format=spec.get('format'),
  compare_to=spec.get('compare_to'), timeline=spec.get('timeline'), period=spec.get('period', 'month'),
  trend=spec.get('trend', false), direction=spec.get('direction', 'higher')
)) %}
{% endmacro %}


{# One chart described as data, for `simple_dashboard` and the other data-driven composites.
   Dispatches on `type`; the keys are the arguments of the matching chart macro (x/y for bar, line,
   area and scatter; category/value for pie and donut), plus `name`, `color`, `stacking`, `sort_by`,
   `labels`, `horizontal` (bar) and `key`. `where` names the caller in error messages. #}
{% macro chart_from_spec(source, spec, where='simple_dashboard') %}
{% set t = spec.get('type') %}
{% set key = spec.get('key') %}
{% if t == 'bar' %}
  {% do return(sigma_workbook.bar_chart(source, spec['x'], spec['y'], color=spec.get('color'), name=spec.get('name'), key=key, stacking=spec.get('stacking'), sort_by=spec.get('sort_by', 'y'), labels=spec.get('labels', false), horizontal=spec.get('horizontal', false))) %}
{% elif t == 'line' %}
  {% do return(sigma_workbook.line_chart(source, spec['x'], spec['y'], color=spec.get('color'), name=spec.get('name'), key=key, sort_by=spec.get('sort_by'))) %}
{% elif t == 'area' %}
  {% do return(sigma_workbook.area_chart(source, spec['x'], spec['y'], color=spec.get('color'), name=spec.get('name'), key=key, stacking=spec.get('stacking'), sort_by=spec.get('sort_by'))) %}
{% elif t == 'pie' %}
  {% do return(sigma_workbook.pie_chart(source, spec['category'], spec['value'], name=spec.get('name'), key=key)) %}
{% elif t == 'donut' %}
  {% do return(sigma_workbook.donut_chart(source, spec['category'], spec['value'], name=spec.get('name'), key=key)) %}
{% elif t == 'scatter' %}
  {% do return(sigma_workbook.scatter_chart(source, spec['x'], spec['y'], color=spec.get('color'), size=spec.get('size'), name=spec.get('name'), key=key)) %}
{% endif %}
{% do sigma_workbook.fail(where, "unknown chart type '" ~ t ~ "' - must be one of bar, line, area, pie, donut, scatter.") %}
{% endmacro %}


{# Filters described as data ({type, name, column}, type one of list, date_range, text), each wired to
   every element in `targets_of`, so one control narrows the whole page. Build controls last: they
   can only target elements that already exist. #}
{% macro filter_controls(filters, targets_of, where='simple_dashboard') %}
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
    {% do sigma_workbook.fail(where, "unknown filter type '" ~ kind ~ "' - must be list, date_range or text.") %}
  {% endif %}
{% endfor %}
{% do return(controls) %}
{% endmacro %}


{# One page laid out as

     title -> filters -> KPI band -> chart rows -> extra elements -> detail table

   from data alone; the body of `simple_dashboard`, and the building block for `simple_leaderboard`.
   `kpis`, `charts`, `filters` and `table_columns` are as in `simple_dashboard`; `extras` are elements you built yourself (a pivot table, a `raw` element), each placed on its own
   row and filtered like the rest. `kpi_h` and `chart_h` set the KPI and chart heights;
   `charts_per_row` how many charts share a row. `where` names the caller in error messages.
   Returns the page, ready for `workbook()`. #}
{% macro dashboard_page(name, source, kpis=[], charts=[], filters=[], table_columns=none, subtitle=none, table_name='Detail', extras=[], kpi_h=5, chart_h=none, charts_per_row=2, where='dashboard_page') %}
{% set source = sigma_workbook.resolve_source(source, where) %}
{% if not (kpis or charts or table_columns or extras) %}
  {% do sigma_workbook.fail(where, "give at least one of kpis, charts or table_columns.") %}
{% endif %}

{% set tiles = [] %}
{% for k in kpis %}
  {% do tiles.append(sigma_workbook.kpi_from_spec(source, k)) %}
{% endfor %}

{% set built = [] %}
{% for c in charts %}
  {% do built.append(sigma_workbook.chart_from_spec(source, c, where)) %}
{% endfor %}

{% set detail = sigma_workbook.table(source, table_columns, name=table_name, key='detail') if table_columns else none %}

{# Controls are built last so they can be wired to every element above. #}
{% set targets_of = tiles + built + extras + ([detail] if detail is not none else []) %}
{% set controls = sigma_workbook.filter_controls(filters, targets_of, where) %}

{% set body = sigma_workbook.dashboard_header(name, subtitle, controls) %}
{% if tiles %}
  {% do body.append(sigma_workbook.row(tiles, 'kpis', h=kpi_h)) %}
{% endif %}
{% for chunk_start in range(0, built | length, charts_per_row) %}
  {% do body.append(sigma_workbook.row(built[chunk_start:chunk_start + charts_per_row], 'charts:' ~ chunk_start, h=chart_h)) %}
{% endfor %}
{% for el in extras %}
  {% do body.append(el) %}
{% endfor %}
{% if detail is not none %}
  {% do body.append(detail) %}
{% endif %}

{% do return(sigma_workbook.page(name, body)) %}
{% endmacro %}


{# A complete one-page dashboard from data alone:

     title -> filters -> KPI band -> chart rows -> detail table

   `kpis` is a list of {value, name, format, compare_to, timeline, period, trend}; `charts` a list of
   chart specs (see chart_from_spec); `filters` a list of {type, name, column} with type one of
   list, date_range, text; `table_columns` the detail table's fields (omit for no table). Filters
   are wired to every KPI, chart and the table, so one control narrows the whole page.

   Every part is optional, so leaving out `table_columns` and passing a few KPIs and one or two charts
   gives a scorecard-style page. For that look, raise `kpi_h` (KPI tile height in rows, default 5) and
   `chart_h` (common chart height, default each chart's own), and set `trend: true` on KPIs that have
   a `timeline` for a sparkline.

   Every piece is just the primitives from elements/ - `simple_dashboard` is the shortest path to
   something on screen, and a template for writing your own layout. #}
{% macro simple_dashboard(name, source, kpis=[], charts=[], filters=[], table_columns=none, subtitle=none, theme={}, table_name='Detail', kpi_h=5, chart_h=none) %}
{% set page = sigma_workbook.dashboard_page(name, source, kpis=kpis, charts=charts, filters=filters, table_columns=table_columns, subtitle=subtitle, table_name=table_name, kpi_h=kpi_h, chart_h=chart_h, where='simple_dashboard') %}
{% do return(sigma_workbook.workbook(name, [page], theme=theme)) %}
{% endmacro %}


{# A leaderboard: who is on top, by which measure.

     title -> filters -> KPI band -> one ranked horizontal bar chart per dimension -> breakdown table

   `dimensions` is a list of fields to rank (a region, a rep, a product); `measure` the field to rank
   them by. Each dimension gets a horizontal bar chart sorted by the measure, largest first, with data
   labels. `detail_measures`, if given, adds a pivot table breaking the first dimension down by the
   measure and those extra measures. `kpis` and `filters` are as in `simple_dashboard`. #}
{% macro simple_leaderboard(name, source, dimensions, measure, measure_name=none, kpis=[], detail_measures=[], filters=[], subtitle=none, theme={}) %}
{% if not dimensions %}
  {% do sigma_workbook.fail('simple_leaderboard', "dimensions is required - list the fields to rank.") %}
{% endif %}
{% set source = sigma_workbook.resolve_source(source, 'simple_leaderboard') %}
{% set measure_label = measure_name or (measure.get('name') if measure is mapping else none) or measure %}
{% set charts = [] %}
{% for dim in dimensions %}
  {% set dim_label = (dim.get('name') or dim.get('formula')) if dim is mapping else sigma_workbook.titleize(dim) %}
  {% do charts.append({
    'type': 'bar', 'x': dim, 'y': measure, 'horizontal': true, 'labels': true,
    'name': measure_label ~ ' by ' ~ dim_label,
  }) %}
{% endfor %}
{% set extras = [] %}
{% if detail_measures %}
  {% set first = dimensions[0] %}
  {% set first_label = (first.get('name') or first.get('formula')) if first is mapping else sigma_workbook.titleize(first) %}
  {% do extras.append(sigma_workbook.pivot_table(source, [measure] + detail_measures, rows=first, name=first_label ~ ' breakdown', key='leaderboard-breakdown')) %}
{% endif %}
{% set page = sigma_workbook.dashboard_page(name, source, kpis=kpis, charts=charts, filters=filters, subtitle=subtitle, extras=extras, where='simple_leaderboard') %}
{% do return(sigma_workbook.workbook(name, [page], theme=theme)) %}
{% endmacro %}
