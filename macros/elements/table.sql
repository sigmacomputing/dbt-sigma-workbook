{# A table element.

     sigma_workbook.table(
       source=sigma_workbook.from_ref('orders'),
       name='Orders',
       columns=['order_id', 'order_date', sigma_workbook.field('Sum([Amount])', name='Revenue')],
       sort=[('order_date', 'desc')],
     )

   `columns` are fields (see field.sql) shown in the order given. `sort` items are a field, or a
   (field, 'asc'|'desc') pair. Charts and controls can use the returned table as their `source`,
   which is how "one table, several views of it" workbooks are built. #}
{% macro table(source, columns, name=none, key=none, w=24, h=14, sort=[], description=none, style=none) %}
{% set source = sigma_workbook.resolve_source(source, 'table') %}
{% if not columns %}
  {% do sigma_workbook.fail('table', "columns is required - list the fields the table should show.") %}
{% endif %}
{% set el = sigma_workbook.new_element('table', 'table', key, name, w, h) %}
{% set cols = [] %}
{% set order = sigma_workbook.add_columns(cols, el['id'], columns, source, 'table') %}
{% do el.update({"source": source, "columns": cols, "order": order}) %}
{% set sorts = [] %}
{% for item in sort %}
  {% set sort_field = item if item is string or item is mapping else item[0] %}
  {% set sort_dir = 'asc' if (item is string or item is mapping) else item[1] %}
  {% do sorts.append({
    "columnId": sigma_workbook.add_column(cols, el['id'], sort_field, source, 'table'),
    "direction": sigma_workbook.direction(sort_dir, 'table'),
  }) %}
{% endfor %}
{% if sorts %}
  {% do el.update({"sort": sorts}) %}
{% endif %}
{% do sigma_workbook.apply_titles(el, name, description) %}
{% do el.update(sigma_workbook.compact({"style": sigma_workbook.card_style(style)})) %}
{% do el.update({"_source": source}) %}
{% do return(el) %}
{% endmacro %}
