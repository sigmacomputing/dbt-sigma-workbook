{# Escape hatches: the package models the common ~80% of a dashboard, and Sigma's schema has hundreds
   of options beyond it. These two macros make sure a missing option is never a dead end.

   extend(el, options)
       Deep-merges raw Sigma properties onto an element you built with a normal macro. Nested mappings
       merge (so you can add one key to `xAxis` without restating the rest); anything else replaces.
       The element is updated in place *and* returned, so controls that already target it keep working.

         {% set chart = sigma_workbook.extend(
              sigma_workbook.bar_chart(orders, 'region', 'Count()', name='Orders'),
              {'barStyle': {'cornerRadius': 'round'}, 'gap': {'width': 'small'}}) %}

   raw(kind, key, properties, w, h)
       An element of any Sigma kind this package has no macro for yet (button, image, embed, gauge-chart,
       combo-chart, ...). `properties` are Sigma's own fields, used as written; the element still takes
       part in layout, duplicate-id checks and private-key stripping like any other.

         {% set open_docs = sigma_workbook.raw('button', 'open_docs', {'text': 'Open docs'}, w=4, h=2) %}

   Raw properties are not validated by this package (it cannot know every kind's rules). Run
   scripts/validate_against_sigma_schema.py to check them against Sigma's published schema. #}
{% macro extend(el, options) %}
{% if el is not mapping or 'id' not in el %}
  {% do sigma_workbook.fail('extend', "expected an element built by a sigma_workbook macro, got " ~ el) %}
{% endif %}
{% for k in options.keys() %}
  {% if k.startswith('_') or k in ['id', 'kind'] %}
    {% do sigma_workbook.fail('extend', "'" ~ k ~ "' can't be overridden - it is managed by the package.") %}
  {% endif %}
  {% if k in el and el[k] is mapping and options[k] is mapping %}
    {% do el.update({k: sigma_workbook.deep_merge(el[k], options[k])}) %}
  {% else %}
    {% do el.update({k: options[k]}) %}
  {% endif %}
{% endfor %}
{% do return(el) %}
{% endmacro %}


{% macro raw(kind, key, properties={}, w=6, h=2) %}
{% set el = sigma_workbook.new_element(kind, 'raw', key, none, w, h) %}
{% for k in properties.keys() %}
  {% if k.startswith('_') or k in ['id', 'kind'] %}
    {% do sigma_workbook.fail('raw', "'" ~ k ~ "' can't be set - it is managed by the package.") %}
  {% endif %}
{% endfor %}
{% do el.update(properties) %}
{% do return(el) %}
{% endmacro %}
