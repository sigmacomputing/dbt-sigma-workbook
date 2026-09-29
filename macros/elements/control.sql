{# Controls: page-level filters that narrow the elements they target.

     sigma_workbook.list_control('Region', targets=[(orders_table, 'region')])
     sigma_workbook.date_range_control('Order date', targets=[(orders_table, 'order_date')])

   `targets` is a list of (element, field) pairs - `element` is a table (or any data element) you
   built earlier in the same workbook, `field` the column to filter on. If that element does not
   have the column yet, it is added to it (hidden from a table's visible `order`, so the table looks
   unchanged). The first target also supplies a list control's selectable values.

   A control's `controlId` is how Sigma formulas refer to it, in the same namespace as column names.
   A control whose id equals a column name that a formula also refers to (a control called "Duration"
   next to `Avg([Duration])`) is a circular dependency in Sigma, so the default id is the lowercase,
   dash-separated `name` plus `-control` ("Region" -> `region-control`). Set `control_id=` to choose
   your own; `workbook()` refuses an id that collides with a column name. #}
{% macro control_element(control_type, where, name, targets, key, control_id, w, h, extras) %}
{% if not targets %}
  {% do sigma_workbook.fail(where, "targets must list at least one (element, field) pair.") %}
{% endif %}
{% set el = sigma_workbook.new_element('control', where, key, name, w, h) %}
{% set filters = [] %}
{% set first = {} %}
{% for target in targets %}
  {% set target_el = target[0] %}
  {% if target_el is not mapping or '_source' not in target_el %}
    {% do sigma_workbook.fail(where, "each target must be (element, field) with an element built by a sigma_workbook data macro, got " ~ target) %}
  {% endif %}
  {% set column_id = sigma_workbook.add_column(target_el['columns'], target_el['id'], target[1], target_el['_source'], where, 'filter') %}
  {% do filters.append({"source": {"kind": "table", "elementId": target_el['id']}, "columnId": column_id}) %}
  {% if not first %}
    {% do first.update({"element": target_el['id'], "column": column_id}) %}
  {% endif %}
{% endfor %}
{% do el.update({
  "controlType": control_type,
  "controlId": control_id or ((name | lower | replace(' ', '-') | replace('_', '-')) ~ '-control'),
  "name": name,
  "filters": filters,
  "_first": first,
}) %}
{% do el.update(extras) %}
{% do return(el) %}
{% endmacro %}


{# A list-of-values control. `default` is a list of pre-selected values; `multiple=false` makes it a
   single-select. #}
{% macro list_control(name, targets, key=none, control_id=none, multiple=true, default=none, w=6, h=2) %}
{% set el = sigma_workbook.control_element('list', 'list_control', name, targets, key, control_id, w, h, {}) %}
{% do el.update({
  "mode": "include",
  "selectionMode": "multiple" if multiple else "single",
  "source": {
    "kind": "source",
    "source": {"kind": "table", "elementId": el['_first']['element']},
    "columnId": el['_first']['column'],
  },
}) %}
{% if default is not none and multiple %}
  {% do el.update({"values": default}) %}
{% elif default is not none %}
  {% do el.update({"value": default[0]}) %}
{% endif %}
{% do return(el) %}
{% endmacro %}


{% macro date_range_control(name, targets, key=none, control_id=none, w=6, h=2) %}
{% do return(sigma_workbook.control_element('date-range', 'date_range_control', name, targets, key, control_id, w, h, {"mode": "between"})) %}
{% endmacro %}


{# Free-text filter. `mode` is one of Sigma's text operators: equals, contains, starts-with, ... #}
{% macro text_control(name, targets, key=none, control_id=none, mode='contains', w=6, h=2) %}
{% do return(sigma_workbook.control_element('text', 'text_control', name, targets, key, control_id, w, h, {"mode": mode})) %}
{% endmacro %}


{% macro number_range_control(name, targets, key=none, control_id=none, minimum=none, maximum=none, w=6, h=2) %}
{% do return(sigma_workbook.control_element('number-range', 'number_range_control', name, targets, key, control_id, w, h, sigma_workbook.compact({"min": minimum, "max": maximum}))) %}
{% endmacro %}
