{# Same path in -> same id out, every compile. Every id the package generates (elements, columns,
   pages, controls) is derived from a stable path - an element's `key`/`name`, a column's formula -
   never from a timestamp, row count or run_started_at, so recompiling an unchanged workbook
   yields a byte-identical spec.

   `length` defaults to 10 characters, which is what Sigma's own generated ids look like. Data
   model table ids are the exception: they use the full 32-character md5 so they match
   `sigma_data_models` exactly (see `sigma_workbook.data_model`). #}
{% macro freeze_id(path, length=10) %}
{% do return(local_md5(path)[:length]) %}
{% endmacro %}
