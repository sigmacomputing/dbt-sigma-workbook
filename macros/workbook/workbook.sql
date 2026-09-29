{# A page: a name and the elements on it. Elements can be passed individually or as lists (the
   composite macros such as `dashboard_header` return lists); lists are flattened one level so
   they can be mixed freely. #}
{% macro page(name, elements, key=none) %}
{% if not elements %}
  {% do sigma_workbook.fail('page', "page '" ~ name ~ "' has no elements.") %}
{% endif %}
{% set flat = [] %}
{% for item in elements %}
  {% if item is mapping %}
    {% do flat.append(item) %}
  {% else %}
    {% for inner in item %}
      {% do flat.append(inner) %}
    {% endfor %}
  {% endif %}
{% endfor %}
{% do return({
  "id": sigma_workbook.freeze_id('page:' ~ (key or name)),
  "name": name,
  "_top_level": flat,
}) %}
{% endmacro %}


{# Depth-first flatten of an element tree into the flat `elements` list Sigma wants: a container is
   listed before its children, and nesting is expressed only in the layout XML. #}
{% macro flatten_elements(elements, acc) %}
{% for el in elements %}
  {% do acc.append(el) %}
  {% if el.get('_children') %}
    {% do sigma_workbook.flatten_elements(el['_children'], acc) %}
  {% endif %}
{% endfor %}
{% endmacro %}


{# Recursively drops every `_`-prefixed key (the package's private layout / bookkeeping fields) so only
   real Sigma fields reach the manifest. #}
{% macro strip_private(value) %}
{% if value is mapping %}
  {% set out = {} %}
  {% for k in value.keys() %}
    {% if not k.startswith('_') %}
      {% do out.update({k: sigma_workbook.strip_private(value[k])}) %}
    {% endif %}
  {% endfor %}
  {% do return(out) %}
{% elif value is sequence and value is not string %}
  {% set out = [] %}
  {% for item in value %}
    {% do out.append(sigma_workbook.strip_private(item)) %}
  {% endfor %}
  {% do return(out) %}
{% endif %}
{% do return(value) %}
{% endmacro %}


{# The top-level macro: assembles pages into a workbook spec in Sigma's code representation
   (https://help.sigmacomputing.com/docs/manage-workbooks-as-code): pages, a flat list of elements, the
   grid `layout` XML that places each element on its page, and the theme as `settings`.

     name        workbook name in Sigma
     pages       list of sigma_workbook.page(...)
     theme       optional per-workbook overrides on top of the project theme (see theme.sql)
     folder_id   Sigma folder to create the workbook in; defaults to the `sigma_folder_id` project var
     workbook_id an existing workbook to update instead of creating a new one (omitted on first create)
     description free-text description
     output      'contents' (default) or 'spec'; defaults to the `sigma_workbook_format` project var

   Two output shapes exist because Sigma's API has two generations of the same representation:

     contents  the request body of `POST /v2/workbooks` (`{name, folderId, description, contents}`), where
               `contents` = `{schemaVersion, kind, pages: [{id, name}], elements: [...], settings, layout}`.
               Elements are one flat list; the `layout` XML is what puts each on its page.
     spec      the body of the deprecated `POST /v2/workbooks/spec`, and the shape shown throughout the
               help-center examples: `{name, schemaVersion, folderId, pages: [{id, name, elements}], ...}`.

   Everything is validated here, at parse time: a workbook with an empty page, a duplicate page name
   or two elements that would share an id fails `dbt parse` rather than reaching Sigma. #}
{% macro workbook(name, pages, theme={}, folder_id=none, workbook_id=none, description=none, output=none) %}
{% set output = output or var('sigma_workbook_format', 'contents') %}
{% if output not in ['contents', 'spec'] %}
  {% do sigma_workbook.fail('workbook', "output must be 'contents' or 'spec', got '" ~ output ~ "'.") %}
{% endif %}
{% if not pages %}
  {% do sigma_workbook.fail('workbook', "pages must not be empty.") %}
{% endif %}
{% set page_names = [] %}
{% set seen_ids = {} %}
{% set out_pages = [] %}
{% set layout_pages = [] %}
{% for p in pages %}
  {% if p['name'] in page_names %}
    {% do sigma_workbook.fail('workbook', "duplicate page name '" ~ p['name'] ~ "' - page names must be unique.") %}
  {% endif %}
  {% do page_names.append(p['name']) %}
  {% set flat = [] %}
  {% do sigma_workbook.flatten_elements(p['_top_level'], flat) %}
  {% for el in flat %}
    {% if el['id'] in seen_ids %}
      {% do sigma_workbook.fail('workbook', "'" ~ el['_key'] ~ "' and '" ~ seen_ids[el['id']] ~ "' resolve to the same element id. Give one of them a distinct `key=`.") %}
    {% endif %}
    {% do seen_ids.update({el['id']: el['_key']}) %}
  {% endfor %}
  {# a control id shares Sigma's formula namespace with column names: a clash is a circular dependency #}
  {% for control in flat if control['kind'] == 'control' %}
    {% for el in flat if el.get('columns') %}
      {% for column in el['columns'] %}
        {% if (sigma_workbook.column_label(column) or '') | lower == control['controlId'] | lower %}
          {% do sigma_workbook.fail('workbook', "control '" ~ control['name'] ~ "' has controlId '" ~ control['controlId'] ~ "', which is also the name of a column on '" ~ el['_key'] ~ "'. Sigma resolves formulas against both, so it becomes a circular dependency - pass a different control_id=.") %}
        {% endif %}
      {% endfor %}
    {% endfor %}
  {% endfor %}
  {% do out_pages.append({
    "id": p['id'],
    "name": p['name'],
    "elements": sigma_workbook.resolve_colors(sigma_workbook.strip_private(flat), sigma_workbook.theme(theme)['colors']),
  }) %}
  {% do layout_pages.append(sigma_workbook.page_layout_xml(p['id'], p['_top_level'], output)) %}
{% endfor %}
{% set settings = sigma_workbook.theme_settings(theme) %}
{% set layout = '<?xml version="1.0" encoding="utf-8"?>\n' ~ (layout_pages | join('\n')) ~ '\n' %}
{% set folder = folder_id or var('sigma_folder_id', none) %}

{% if output == 'spec' %}
  {% set spec = {"name": name, "schemaVersion": 1} %}
  {% do spec.update({"pages": out_pages, "settings": settings, "layout": layout}) %}
{% else %}
  {% set flat_elements = [] %}
  {% set page_stubs = [] %}
  {% for p in out_pages %}
    {% do page_stubs.append({"id": p['id'], "name": p['name']}) %}
    {% for el in p['elements'] %}{% do flat_elements.append(el) %}{% endfor %}
  {% endfor %}
  {% set spec = {"name": name, "contents": {
    "schemaVersion": 1,
    "kind": "workbook",
    "pages": page_stubs,
    "elements": flat_elements,
    "settings": settings,
    "layout": layout,
  }} %}
{% endif %}
{% if folder %}
  {% do spec.update({"folderId": folder}) %}
{% endif %}
{% if workbook_id %}
  {% do spec.update({"workbookId": workbook_id}) %}
{% endif %}
{% if description %}
  {% do spec.update({"description": description}) %}
{% endif %}
{% do return(spec) %}
{% endmacro %}


{# Attaches a composed spec to the calling dbt model's `meta`, where it lands in manifest.json on
   `dbt parse` / `dbt compile`. The model body still has to be valid SQL; a one-line `select 1`
   is conventional. `materialized` defaults to `view` (the cheapest object every adapter supports);
   use `ephemeral` to avoid creating anything in the warehouse. #}
{% macro materialize(spec, materialized='view') %}
{{ config(materialized=materialized, meta={'sigma_workbook': spec}) }}
{% endmacro %}
