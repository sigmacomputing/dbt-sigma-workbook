{# `snake_case` / `kebab-case` / `lowercase` -> `Title Case`. Anything that already contains an
   uppercase letter is returned untouched, so 'ARR' and 'Order ID' survive. #}
{% macro titleize(value) %}
{% set value = value | string %}
{% if value != value | lower %}
  {% do return(value) %}
{% endif %}
{% do return(value.replace('_', ' ').replace('-', ' ').title()) %}
{% endmacro %}


{# Drops keys whose value is none, so optional Sigma fields are omitted rather than emitted as null. #}
{% macro compact(mapping) %}
{% set out = {} %}
{% for k in mapping.keys() %}
  {% if mapping[k] is not none %}
    {% do out.update({k: mapping[k]}) %}
  {% endif %}
{% endfor %}
{% do return(out) %}
{% endmacro %}


{# Recursive dict merge: keys in `override` win; nested mappings merge rather than replace. #}
{% macro deep_merge(base, override) %}
{% set out = {} %}
{% for k in base.keys() %}
  {% do out.update({k: base[k]}) %}
{% endfor %}
{% for k in override.keys() %}
  {% if k in out and out[k] is mapping and override[k] is mapping %}
    {% do out.update({k: sigma_workbook.deep_merge(out[k], override[k])}) %}
  {% else %}
    {% do out.update({k: override[k]}) %}
  {% endif %}
{% endfor %}
{% do return(out) %}
{% endmacro %}


{# Raises a compiler error prefixed with the calling macro's name. Every validation in the package
   goes through here so messages read consistently. `execute` is deliberately not checked: specs
   are composed at parse time, and a malformed spec must fail `dbt parse`, not slip into the
   manifest. #}
{% macro fail(where, message) %}
{% do exceptions.raise_compiler_error('sigma_workbook.' ~ where ~ ': ' ~ message) %}
{% endmacro %}
