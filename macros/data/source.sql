{# Data sources: where an element gets its rows. A source is a plain dict in Sigma's own `source`
   shape plus a private `_name` (the prefix Sigma uses in `[NAME/Column]` formulas). Private keys
   start with `_` and are stripped by `sigma_workbook.workbook()` before the spec is emitted.

   Three kinds are supported, mirroring how Sigma workbooks are actually fed:

     warehouse_table / from_ref  ->  a table in the warehouse (a raw table or any dbt model)
     data_model / from_data_model ->  a table inside a Sigma data model (see `sigma_data_models`)
     element                      ->  another element in the same workbook (chart on a table)

   Every element macro accepts any of these as `source=`, or an element dict directly (which is
   shorthand for `sigma_workbook.element(that_element)`). #}


{# A warehouse table addressed by its physical path. `path` is [database, schema, table]. #}
{% macro warehouse_table(path, connection_id=none) %}
{% set connection_id = connection_id or var('sigma_connection_id', none) %}
{% if not connection_id %}
  {% do sigma_workbook.fail('warehouse_table', "connection_id is required but was not set. Pass connection_id=, or set the `sigma_connection_id` project var in dbt_project.yml.") %}
{% endif %}
{% if path | length != 3 %}
  {% do sigma_workbook.fail('warehouse_table', "path must be [database, schema, table], got " ~ path) %}
{% endif %}
{% do return({
  "kind": "warehouse-table",
  "connectionId": connection_id,
  "path": path,
  "_name": path[-1],
}) %}
{% endmacro %}


{# A dbt model (or seed / snapshot) as a warehouse table. Calls `ref()` so the workbook model shows
   up downstream of it in the DAG and in dbt docs lineage.

   The physical path is taken from `database` / `schema` / `identifier`, defaulting to the target's
   database + schema and the model name. It is deliberately not read back from `ref()`: a workbook
   spec is composed at parse time, and at parse time `ref()` cannot resolve other models' relations.
   If your models build into a custom schema or alias, pass `schema=` / `identifier=` (or set them
   once via a wrapper macro in your project). #}
{% macro from_ref(model_name, database=none, schema=none, identifier=none, connection_id=none) %}
{% do ref(model_name) %}
{% do return(sigma_workbook.warehouse_table(
  [database or target.database, schema or target.schema, identifier or model_name],
  connection_id
)) %}
{% endmacro %}


{# A table inside a Sigma data model.

     data_model_id  the Sigma data model's id; falls back to `var('sigma_data_model_ids')[dbt_model]`
     table_key      the `key` the table was given in `sigma_data_models.table(...)`

   `database` / `schema` / `identifier` must match what was passed to that `sigma_data_models.table()`
   call (same defaults: target database + schema, identifier = table_key) because the table's
   element id is derived from them - the same derivation `sigma_data_models` uses, so the ids agree
   without any coordination between the two packages.

   Columns are referenced as `[Table Name/Column]`, where Table Name is the table's display name in
   the data model: `sigma_data_models` defaults it to the title-cased `key` ('orders' -> 'Orders').
   If the table was given a custom `display_name=`, pass the same as `table_name=`. #}
{% macro data_model(data_model_id, table_key, identifier=none, database=none, schema=none, table_name=none) %}
{% set database = database or target.database %}
{% set schema = schema or target.schema %}
{% set identifier = identifier or table_key %}
{% set scope = table_key ~ '@' ~ ((database ~ '.' ~ schema ~ '.' ~ identifier) | lower) %}
{% do return({
  "kind": "data-model",
  "dataModelId": data_model_id,
  "elementId": sigma_workbook.freeze_id('table:' ~ scope, 32),
  "_name": table_name or sigma_workbook.titleize(table_key),
}) %}
{% endmacro %}


{# `data_model` for a dbt model built with `sigma_data_models.materialize()`: `ref()`s that model
   for lineage, and looks its Sigma data model id up in the `sigma_data_model_ids` project var
   (a {dbt_model_name: sigma_data_model_id} mapping), since the id only exists once the data model
   has been created in Sigma. An id that hasn't been recorded yet is emitted as an obvious
   `unresolved:<model>` placeholder - the export/deploy script refuses to push those. #}
{% macro from_data_model(model_name, table_key, data_model_id=none, identifier=none, database=none, schema=none, table_name=none) %}
{% do ref(model_name) %}
{% set resolved_id = data_model_id or var('sigma_data_model_ids', {}).get(model_name) or ('unresolved:' ~ model_name) %}
{% do return(sigma_workbook.data_model(resolved_id, table_key, identifier, database, schema, table_name)) %}
{% endmacro %}


{# Another element in the same workbook as a source. Elements are already dicts, so this is mostly
   a readability aid: `sigma_workbook.bar_chart(source=sigma_workbook.element(orders), ...)`. #}
{% macro element(el) %}
{% if el is not mapping or 'id' not in el %}
  {% do sigma_workbook.fail('element', "expected an element built by a sigma_workbook macro (a dict with an `id`), got " ~ el) %}
{% endif %}
{# `_name` and `_columns` (the parent's live column list) let a child element refer to the parent's
   columns the way Sigma does - see field.sql. #}
{% do return({
  "kind": "table",
  "elementId": el['id'],
  "_name": (el.get('_source') or {}).get('_name'),
  "_columns": el.get('columns', []),
}) %}
{% endmacro %}


{# Normalizes anything a caller might pass as `source=` into a source dict. #}
{% macro resolve_source(source, where) %}
{% if source is not mapping %}
  {% do sigma_workbook.fail(where, "source must be a sigma_workbook source or element, got " ~ source) %}
{% endif %}
{% if 'elementId' in source or 'connectionId' in source or 'dataModelId' in source %}
  {% do return(source) %}
{% endif %}
{% if 'id' in source and 'kind' in source %}
  {% do return(sigma_workbook.element(source)) %}
{% endif %}
{% do sigma_workbook.fail(where, "source must be a sigma_workbook source or element, got " ~ source) %}
{% endmacro %}
