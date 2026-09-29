{# A pivot table.

     sigma_workbook.pivot_table(source=orders, rows='region', cols='segment',
                                values='Sum([Amount])', name='Revenue by region and segment')

   `rows` and `cols` are one field or a list of fields (each becomes a grouping level); `values` is
   one measure or a list of them. Either `rows` or `cols` may be omitted. #}
{% macro pivot_table(source, values, rows=none, cols=none, name=none, key=none, w=24, h=14, description=none, style=none) %}
{% set source = sigma_workbook.resolve_source(source, 'pivot_table') %}
{% if rows is none and cols is none %}
  {% do sigma_workbook.fail('pivot_table', "give at least one of `rows` or `cols`.") %}
{% endif %}
{% set el = sigma_workbook.new_element('pivot-table', 'pivot_table', key, name, w, h) %}
{% set columns = [] %}
{% set value_ids = sigma_workbook.add_columns(columns, el['id'], values, source, 'pivot_table', 'values') %}
{% do el.update({"source": source, "columns": columns, "values": value_ids, "_source": source}) %}
{% if rows is not none %}
  {% set row_levels = [] %}
  {% for column_id in sigma_workbook.add_columns(columns, el['id'], rows, source, 'pivot_table', 'rows') %}
    {% do row_levels.append({"columnId": column_id}) %}
  {% endfor %}
  {% do el.update({"rowsBy": row_levels}) %}
{% endif %}
{% if cols is not none %}
  {% set col_levels = [] %}
  {% for column_id in sigma_workbook.add_columns(columns, el['id'], cols, source, 'pivot_table', 'cols') %}
    {% do col_levels.append({"columnId": column_id}) %}
  {% endfor %}
  {% do el.update({"columnsBy": col_levels}) %}
{% endif %}
{% do sigma_workbook.apply_titles(el, name, description) %}
{% do el.update(sigma_workbook.compact({"style": sigma_workbook.card_style(style)})) %}
{% do return(el) %}
{% endmacro %}
