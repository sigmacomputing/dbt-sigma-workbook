{# Fields: the unit every axis, value and column in a component is described with.

   A field can be written three ways, shortest first:

     'region'                                   a source column   -> [Region]  (prefixed for warehouse sources)
     'Sum([Amount])'                            a formula, passed through as written
     sigma_workbook.field('Sum([Amount])', name='Revenue', format=sigma_workbook.format_currency())

   A bare string that is all lowercase is a column name and is title-cased the way Sigma title-cases
   warehouse columns ('order_date' -> [Order Date]). Anything containing `[` or `(`, or any
   uppercase letter, is treated as an already-written formula and never rewritten.

   How columns are referenced (this follows what Sigma itself writes when it exports a workbook):

     * a column read straight from a warehouse or data model table is qualified with the table's
       name - `[TRIP/Start Station Name]`;
     * formulas refer to columns unqualified - `Sum([Duration])` - and the element carries the
       qualified passthrough column `[TRIP/Duration]` alongside, so `add_column` adds that passthrough
       automatically for every unqualified reference it finds;
     * an element built on another element (a chart on a table) uses the parent's column the same
       way: the parent's qualified passthrough, or the parent's calculated column by name. #}
{% macro field(formula, name=none, format=none, description=none) %}
{% do return(sigma_workbook.compact({
  "formula": formula,
  "name": name,
  "format": format,
  "description": description,
})) %}
{% endmacro %}


{# The display name Sigma shows for a column: its `name`, or the column part of a plain reference
   like `[TRIP/Id]` / `[Id]`. Calculated columns without a name have none (returns none). #}
{% macro column_label(column) %}
{% if column.get('name') %}
  {% do return(column['name']) %}
{% endif %}
{% set formula = column['formula'] %}
{% if formula.startswith('[') and formula.endswith(']') and '(' not in formula and formula.count('[') == 1 %}
  {% do return(formula[1:-1].split('/')[-1]) %}
{% endif %}
{% do return(none) %}
{% endmacro %}


{# `[TABLE/Column]` when `formula` is a plain qualified passthrough reference. #}
{% macro is_qualified_reference(formula) %}
{% do return(formula.startswith('[') and formula.endswith(']') and '/' in formula and '(' not in formula and formula.count('[') == 1) %}
{% endmacro %}


{# How `column` (a name exactly as Sigma shows it) is referred to from a column list, given the source
   the element reads from. `columns_by_label` is used only for element sources. #}
{% macro reference_to(column, source) %}
{% if source.get('kind') == 'table' %}
  {% for parent_column in source.get('_columns', []) %}
    {% if sigma_workbook.column_label(parent_column) == column %}
      {% if sigma_workbook.is_qualified_reference(parent_column['formula']) %}
        {% do return(parent_column['formula']) %}
      {% endif %}
      {% do return('[' ~ column ~ ']') %}
    {% endif %}
  {% endfor %}
{% endif %}
{% if source.get('_name') %}
  {% do return('[' ~ source['_name'] ~ '/' ~ column ~ ']') %}
{% endif %}
{% do return('[' ~ column ~ ']') %}
{% endmacro %}


{# The Sigma formula for a field written as a bare string. See the rules above. #}
{% macro formula_for(text, source) %}
{% if '[' in text or '(' in text %}
  {% do return(text) %}
{% endif %}
{% set column = sigma_workbook.titleize(text) if text == text | lower else text %}
{% do return(sigma_workbook.reference_to(column, source)) %}
{% endmacro %}


{# Turns 'region' / 'Sum([Amount])' / a field() dict into a field dict with a resolved `formula`. #}
{% macro normalize_field(f, source, where) %}
{% if f is string %}
  {% do return({"formula": sigma_workbook.formula_for(f, source)}) %}
{% endif %}
{% if f is not mapping or 'formula' not in f %}
  {% do sigma_workbook.fail(where, "a field must be a string or sigma_workbook.field(...), got " ~ f) %}
{% endif %}
{% set out = {} %}
{% for k in f.keys() %}
  {% do out.update({k: f[k]}) %}
{% endfor %}
{% do out.update({"formula": sigma_workbook.formula_for(f['formula'], source)}) %}
{% do return(out) %}
{% endmacro %}


{# The unqualified column names a formula refers to: `Sum([Amount]) / Count([Order Id])` -> [Amount,
   Order Id]. References already qualified with `TABLE/` are skipped. #}
{% macro referenced_columns(formula) %}
{% set names = [] %}
{% for part in formula.split('[')[1:] %}
  {% if ']' in part %}
    {% set token = part.split(']')[0] %}
    {% if '/' not in token and token not in names %}
      {% do names.append(token) %}
    {% endif %}
  {% endif %}
{% endfor %}
{% do return(names) %}
{% endmacro %}


{# Makes sure every column a formula refers to unqualified has its passthrough column on the element
   (see the header). A reference to a column the element already has - including a calculated column
   by its name - needs nothing. #}
{% macro ensure_references(columns, element_id, formula, source) %}
{% for token in sigma_workbook.referenced_columns(formula) %}
  {% set known = namespace(found=false) %}
  {% for existing in columns %}
    {% if sigma_workbook.column_label(existing) == token %}{% set known.found = true %}{% endif %}
  {% endfor %}
  {% if not known.found %}
    {% set passthrough = sigma_workbook.reference_to(token, source) %}
    {% do columns.append({
      "id": sigma_workbook.freeze_id(element_id ~ ':column:' ~ passthrough ~ '|'),
      "formula": passthrough,
    }) %}
  {% endif %}
{% endfor %}
{% endmacro %}


{# Registers a field as a column on an element and returns its column id.

   `columns` is the element's column list, mutated in place. The id is derived from the element id
   plus the field's formula and name, so the same field used twice on one element (e.g. a KPI's value
   and its comparison) reuses one column instead of creating a duplicate. Passthrough columns for
   unqualified references in the formula are added too (see ensure_references).

   `role` names the channel the column feeds (x, y, color, comparison, ...). Sigma allows a column on
   only one channel of an element ("referenced from both 'value' and 'comparison'"), so the role is
   part of the id: the same formula on two channels becomes two columns, as it does in Sigma's own
   exports. Columns in the same role - or with no role, as in a table - are shared. #}
{% macro add_column(columns, element_id, f, source, where, role='') %}
{% set f = sigma_workbook.normalize_field(f, source, where) %}
{% set column_id = sigma_workbook.freeze_id(element_id ~ ':column:' ~ f['formula'] ~ '|' ~ (f.get('name') or '') ~ ('|' ~ role if role else '')) %}
{% for existing in columns %}
  {% if existing['id'] == column_id %}
    {% do return(column_id) %}
  {% endif %}
{% endfor %}
{% do columns.append(sigma_workbook.compact({
  "id": column_id,
  "formula": f['formula'],
  "name": f.get('name'),
  "description": f.get('description'),
  "format": f.get('format'),
})) %}
{% do sigma_workbook.ensure_references(columns, element_id, f['formula'], source) %}
{% do return(column_id) %}
{% endmacro %}


{# Same as add_column for a list of fields; returns the list of column ids, in order. #}
{% macro add_columns(columns, element_id, fields, source, where, role='') %}
{% set ids = [] %}
{% for f in (fields if fields is not string and fields is not mapping else [fields]) %}
  {% do ids.append(sigma_workbook.add_column(columns, element_id, f, source, where, role)) %}
{% endfor %}
{% do return(ids) %}
{% endmacro %}
