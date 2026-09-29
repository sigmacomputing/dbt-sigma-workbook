{# Shared scaffolding for every element macro.

   An element is a plain dict in Sigma's own element shape (`id`, `kind`, `columns`, ...) plus a few
   private `_`-prefixed keys the layout engine reads and `sigma_workbook.workbook()` strips:

     _w, _h      grid footprint in the page's 24-column grid (a caller can override via w= / h=)
     _key        the identity the id was derived from (for duplicate-id error messages)
     _children   elements nested inside a container

   Element ids come from the element's kind plus its `key` (or, failing that, `name`). Two elements
   of the same kind sharing a name therefore need distinct `key=`s - `workbook()` raises if they don't,
   rather than letting Sigma silently merge them. #}
{% macro new_element(kind, where, key, name, w, h) %}
{% set identity = key or name %}
{% if not identity %}
  {% do sigma_workbook.fail(where, "set `name=` or `key=` so the element gets a stable id.") %}
{% endif %}
{% do return({
  "id": sigma_workbook.freeze_id('element:' ~ kind ~ ':' ~ identity),
  "kind": kind,
  "_key": kind ~ ':' ~ identity,
  "_w": w,
  "_h": h,
}) %}
{% endmacro %}


{# The default look of a data element (chart, table, KPI, pivot): a white card with a hairline border.
   Switch it off project-wide with `sigma_workbook_theme: {cards: false}`, or per element by passing
   `style=`. #}
{% macro card_style(style=none) %}
{% if style is not none %}
  {% do return(style) %}
{% endif %}
{% if not sigma_workbook.theme()['cards'] %}
  {% do return(none) %}
{% endif %}
{% do return({
  "backgroundColor": sigma_workbook.color_ref('surface'),
  "borderRadius": "round",
  "borderWidth": 1,
  "borderColor": sigma_workbook.color_ref('hairline'),
}) %}
{% endmacro %}


{# 'asc' / 'desc' (or the full words) -> Sigma's 'ascending' / 'descending'. #}
{% macro direction(value, where) %}
{% if value in ['asc', 'ascending'] %}
  {% do return('ascending') %}
{% elif value in ['desc', 'descending'] %}
  {% do return('descending') %}
{% endif %}
{% do sigma_workbook.fail(where, "sort direction must be 'asc' or 'desc', got '" ~ value ~ "'.") %}
{% endmacro %}


{# Title / description in the shapes Sigma accepts. Charts, tables and pivots take a plain string for
   `description`; KPIs take an object - callers handle that themselves. #}
{% macro apply_titles(el, name, description) %}
{% if name is not none %}
  {% do el.update({"name": name}) %}
{% endif %}
{% if description is not none %}
  {% do el.update({"description": description}) %}
{% endif %}
{% endmacro %}
