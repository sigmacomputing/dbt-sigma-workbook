{# Number / datetime display formats, in Sigma's own shape. Pass the result as `format=` on a field:

     sigma_workbook.field('Sum([Amount])', name='Revenue', format=sigma_workbook.format_currency())

   `format()` is the generic constructor (validated against the option keys Sigma documents at
   https://help.sigmacomputing.com/docs/format-columns-and-metrics-in-the-code-representation-of-a-data-model);
   the `format_*` macros below are the common cases. #}
{% macro format(kind, options={}) %}
{% if kind not in ['number', 'datetime'] %}
  {% do sigma_workbook.fail('format', "kind must be 'number' or 'datetime', got '" ~ kind ~ "'.") %}
{% endif %}
{% set allowed = {
  'number': ['formatString', 'decimalSymbol', 'digitGroupingSymbol', 'digitGroupingSize', 'currencySymbol', 'prefix', 'suffix', 'displayNullAs'],
  'datetime': ['formatString'],
} %}
{% for key in options.keys() %}
  {% if key not in allowed[kind] %}
    {% do sigma_workbook.fail('format', "'" ~ key ~ "' is not a supported option for kind='" ~ kind ~ "'. Allowed: " ~ (allowed[kind] | join(', ')) ~ ".") %}
  {% endif %}
{% endfor %}
{% set result = {"kind": kind} %}
{% do result.update(options) %}
{% do return(result) %}
{% endmacro %}


{% macro format_number(decimals=0) %}
{% do return(sigma_workbook.format('number', {
  "formatString": "." ~ decimals ~ "f",
  "decimalSymbol": ".",
  "digitGroupingSymbol": ",",
  "digitGroupingSize": [3],
})) %}
{% endmacro %}


{% macro format_currency(decimals=0, symbol='$') %}
{% do return(sigma_workbook.format('number', {
  "formatString": symbol ~ "." ~ decimals ~ "f",
  "decimalSymbol": ".",
  "digitGroupingSymbol": ",",
  "digitGroupingSize": [3],
  "currencySymbol": symbol,
})) %}
{% endmacro %}


{% macro format_percent(decimals=1) %}
{% do return(sigma_workbook.format('number', {"formatString": "." ~ decimals ~ "%"})) %}
{% endmacro %}


{% macro format_date(pattern='%b %d, %Y') %}
{% do return(sigma_workbook.format('datetime', {"formatString": pattern})) %}
{% endmacro %}
