{# Cartesian charts: bar, line, area and scatter. They share one assembler (`xy_chart`) so they stay
   consistent; the public macros just pick a kind and a sensible default sort.

     sigma_workbook.bar_chart(source=orders, x='region', y='Sum([Amount])', name='Revenue by region')
     sigma_workbook.line_chart(source=orders, x='DateTrunc("month", [Order Date])', y='Count()',
                               color='segment', name='Orders by month')

   Common arguments
     x            one field (the category / time axis)
     y            one field, or a list of fields to plot several measures
     color        a field to split the series by; omitted = every mark in the theme's primary color
     sort_by      'x', 'y' or a field; `sort_direction` is 'asc' or 'desc'. Bars sort by their first
                  measure, descending, unless told otherwise; lines and areas keep the axis order
     stacking     bar and area only: 'stacked' or 'normalized'
     labels       true = show data labels
     legend       false = hide the legend
     style        overrides the default card look (see card_style) #}
{% macro xy_chart(kind, where, source, x, y, color, name, key, w, h, description, sort_by, sort_direction, stacking, labels, legend, orientation, style) %}
{% set source = sigma_workbook.resolve_source(source, where) %}
{% set el = sigma_workbook.new_element(kind, where, key, name, w, h) %}
{% set cols = [] %}
{% set x_id = sigma_workbook.add_column(cols, el['id'], x, source, where, 'x') %}
{% set y_ids = sigma_workbook.add_columns(cols, el['id'], y, source, where, 'y') %}
{% do el.update({
  "source": source,
  "columns": cols,
  "xAxis": {"columnId": x_id},
  "yAxis": {"columnIds": y_ids},
  "_source": source,
}) %}
{% if sort_by is not none %}
  {% if sort_by == 'x' %}
    {% set sort_id = x_id %}
  {% elif sort_by == 'y' %}
    {% set sort_id = y_ids[0] %}
  {% else %}
    {% set sort_id = sigma_workbook.add_column(cols, el['id'], sort_by, source, where, 'sort') %}
  {% endif %}
  {% do el['xAxis'].update({"sort": {"by": sort_id, "direction": sigma_workbook.direction(sort_direction, where)}}) %}
{% endif %}
{% if color is not none %}
  {# No per-chart `scheme`: Sigma colors categories from the workbook theme's categoricalScheme. #}
  {% do el.update({"color": {"by": "category", "column": sigma_workbook.add_column(cols, el['id'], color, source, where, 'color')}}) %}
{% else %}
  {% do el.update({"color": {"by": "single", "value": sigma_workbook.color_ref('primary')}}) %}
{% endif %}
{% if stacking is not none %}
  {% do el.update({"stacking": stacking}) %}
{% endif %}
{% if orientation is not none %}
  {% do el.update({"orientation": orientation}) %}
{% endif %}
{% if labels %}
  {% do el.update({"dataLabel": {"labels": "shown"}}) %}
{% endif %}
{% if legend is sameas false %}
  {% do el.update({"legend": {"visibility": "hidden"}}) %}
{% endif %}
{% do sigma_workbook.apply_titles(el, name, description) %}
{% do el.update(sigma_workbook.compact({"style": sigma_workbook.card_style(style)})) %}
{% do return(el) %}
{% endmacro %}


{% macro bar_chart(source, x, y, color=none, name=none, key=none, w=12, h=14, description=none, sort_by='y', sort_direction='desc', stacking=none, labels=false, legend=true, horizontal=false, style=none) %}
{% do return(sigma_workbook.xy_chart('bar-chart', 'bar_chart', source, x, y, color, name, key, w, h, description, sort_by, sort_direction, stacking, labels, legend, 'horizontal' if horizontal else none, style)) %}
{% endmacro %}


{% macro line_chart(source, x, y, color=none, name=none, key=none, w=12, h=14, description=none, sort_by=none, sort_direction='asc', labels=false, legend=true, style=none) %}
{% do return(sigma_workbook.xy_chart('line-chart', 'line_chart', source, x, y, color, name, key, w, h, description, sort_by, sort_direction, none, labels, legend, none, style)) %}
{% endmacro %}


{% macro area_chart(source, x, y, color=none, name=none, key=none, w=12, h=14, description=none, sort_by=none, sort_direction='asc', stacking=none, labels=false, legend=true, style=none) %}
{% do return(sigma_workbook.xy_chart('area-chart', 'area_chart', source, x, y, color, name, key, w, h, description, sort_by, sort_direction, stacking, labels, legend, none, style)) %}
{% endmacro %}


{# Scatter: `x` and `y` are both measures; `size` optionally scales the marks. #}
{% macro scatter_chart(source, x, y, color=none, size=none, name=none, key=none, w=12, h=14, description=none, legend=true, style=none) %}
{% set el = sigma_workbook.xy_chart('scatter-chart', 'scatter_chart', source, x, y, color, name, key, w, h, description, none, 'asc', none, false, legend, none, style) %}
{% if size is not none %}
  {% do el.update({"size": {"columnId": sigma_workbook.add_column(el['columns'], el['id'], size, el['_source'], 'scatter_chart', 'size')}}) %}
{% endif %}
{% do return(el) %}
{% endmacro %}


{# Part-to-whole charts. `category` is the slice field, `value` the measure. #}
{% macro part_to_whole(kind, where, source, category, value, name, key, w, h, description, labels, legend, style) %}
{% set source = sigma_workbook.resolve_source(source, where) %}
{% set el = sigma_workbook.new_element(kind, where, key, name, w, h) %}
{% set cols = [] %}
{% set category_id = sigma_workbook.add_column(cols, el['id'], category, source, where, 'color') %}
{% set value_id = sigma_workbook.add_column(cols, el['id'], value, source, where, 'value') %}
{% do el.update({
  "source": source,
  "columns": cols,
  "color": {"columnId": category_id},
  "value": {"columnId": value_id},
  "_source": source,
}) %}
{% if labels %}
  {% do el.update({"dataLabel": {"labels": "shown", "labelDisplay": "percent"}}) %}
{% endif %}
{% if legend is sameas false %}
  {% do el.update({"legend": {"visibility": "hidden"}}) %}
{% endif %}
{% do sigma_workbook.apply_titles(el, name, description) %}
{% do el.update(sigma_workbook.compact({"style": sigma_workbook.card_style(style)})) %}
{% do return(el) %}
{% endmacro %}


{% macro pie_chart(source, category, value, name=none, key=none, w=8, h=14, description=none, labels=true, legend=true, style=none) %}
{% do return(sigma_workbook.part_to_whole('pie-chart', 'pie_chart', source, category, value, name, key, w, h, description, labels, legend, style)) %}
{% endmacro %}


{# Donut: same as pie, plus an optional `hole_value` measure shown in the middle. #}
{% macro donut_chart(source, category, value, hole_value=none, name=none, key=none, w=8, h=14, description=none, labels=true, legend=true, style=none) %}
{% set el = sigma_workbook.part_to_whole('donut-chart', 'donut_chart', source, category, value, name, key, w, h, description, labels, legend, style) %}
{% if hole_value is not none %}
  {% do el.update({"holeValue": {"columnId": sigma_workbook.add_column(el['columns'], el['id'], hole_value, el['_source'], 'donut_chart', 'hole')}}) %}
{% endif %}
{% do return(el) %}
{% endmacro %}
