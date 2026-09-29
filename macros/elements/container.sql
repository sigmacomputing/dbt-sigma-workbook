{# A container: a box that groups elements and lays them out on its own 24-column grid.

     sigma_workbook.container(key='kpis', elements=[kpi_a, kpi_b, kpi_c])

   Containers nest. By default a container is invisible (no fill, no border, no padding) so it is
   purely structural; pass `card=true` to give it the card look. Its height is derived from its
   children unless `h=` is set. #}
{% macro container(elements, key, name=none, w=24, h=none, card=false, style=none) %}
{% if not elements %}
  {% do sigma_workbook.fail('container', "elements must not be empty.") %}
{% endif %}
{% set el = sigma_workbook.new_element('container', 'container', key, name, w, h) %}
{% set placed = sigma_workbook.place(elements) %}
{% if h is none %}
  {% do el.update({"_h": placed['rows'] + (2 if card else 0)}) %}
{% endif %}
{% if style is not none %}
  {% do el.update({"style": style}) %}
{% elif card %}
  {% do el.update(sigma_workbook.compact({"style": sigma_workbook.card_style()})) %}
{% else %}
  {% do el.update({"style": {"padding": "none", "backgroundColor": "transparent"}}) %}
{% endif %}
{% do el.update({"_children": elements}) %}
{% do return(el) %}
{% endmacro %}
