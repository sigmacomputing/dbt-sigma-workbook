{# Correctness checks for the compiled workbook specs, run with `dbt run-operation assert_workbooks`.

   They assert the *shape* of what lands in manifest.json - the field names, nesting and cross-references
   the request body of Sigma's `POST /v2/workbooks` (`contents`) requires - not merely that compilation
   succeeded. See integration_tests/README.md for the mapping from each assertion to the Sigma docs. #}

{% macro _ok(condition, message) %}
{% if not condition %}
  {% do exceptions.raise_compiler_error('ASSERTION FAILED: ' ~ message) %}
{% endif %}
{% endmacro %}


{% macro _spec_of(model_name) %}
{% for node in graph.nodes.values() %}
  {% if node.resource_type == 'model' and node.name == model_name %}
    {% do return(node.config.meta.sigma_workbook) %}
  {% endif %}
{% endfor %}
{% do exceptions.raise_compiler_error('ASSERTION FAILED: model ' ~ model_name ~ ' has no sigma_workbook meta') %}
{% endmacro %}


{% macro _data_model_spec_of(model_name) %}
{% for node in graph.nodes.values() %}
  {% if node.resource_type == 'model' and node.name == model_name %}
    {% do return(node.config.meta.sigma_data_model) %}
  {% endif %}
{% endfor %}
{% do exceptions.raise_compiler_error('ASSERTION FAILED: model ' ~ model_name ~ ' has no sigma_data_model meta') %}
{% endmacro %}


{# First element of `kind` whose title text (or, for a plain-string name, the name) matches `title`;
   `title` none matches any. #}
{% macro _find(elements, kind, title) %}
{% for el in elements %}
  {% if el.kind == kind %}
    {% set shown = el.name.text if el.get('name') is mapping else el.get('name') %}
    {% set shown = shown if shown is not none else '' %}
    {% if title is none or shown == title %}
      {% do return(el) %}
    {% endif %}
  {% endif %}
{% endfor %}
{% do exceptions.raise_compiler_error('ASSERTION FAILED: no ' ~ kind ~ ' titled ' ~ title) %}
{% endmacro %}


{# Every key anywhere in a structure, so we can catch leaked private keys. #}
{% macro _all_keys(value, acc) %}
{% if value is mapping %}
  {% for k in value.keys() %}
    {% do acc.append(k) %}
    {% do sigma_workbook_integration_tests._all_keys(value[k], acc) %}
  {% endfor %}
{% elif value is sequence and value is not string %}
  {% for item in value %}
    {% do sigma_workbook_integration_tests._all_keys(item, acc) %}
  {% endfor %}
{% endif %}
{% endmacro %}


{# Structural invariants that must hold for *every* workbook this package emits. #}
{% macro _check_workbook(model_name) %}
{% set spec = sigma_workbook_integration_tests._spec_of(model_name) %}
{% set c = spec.contents %}
{% set where = model_name ~ ': ' %}

{# ---- the POST /v2/workbooks request body ---- #}
{% do sigma_workbook_integration_tests._ok(spec.name, where ~ 'name is set') %}
{% do sigma_workbook_integration_tests._ok(spec.folderId, where ~ 'folderId comes from the sigma_folder_id var') %}
{% do sigma_workbook_integration_tests._ok(c.schemaVersion == 1 and c.kind == 'workbook', where ~ 'contents has schemaVersion 1 and kind workbook') %}
{% do sigma_workbook_integration_tests._ok(c.pages | length > 0 and c.elements | length > 0, where ~ 'contents has pages and elements') %}
{% do sigma_workbook_integration_tests._ok(c.settings.theme.overrides.colors.highlight, where ~ 'theme sets the highlight color') %}
{% do sigma_workbook_integration_tests._ok(c.layout.startswith('<?xml version="1.0" encoding="utf-8"?>'), where ~ 'layout is an XML document') %}
{% do sigma_workbook_integration_tests._ok('workbookId' not in spec, where ~ 'no workbookId on a first-time create') %}

{# ---- no private keys or unresolved placeholders leak ---- #}
{% set keys = [] %}
{% do sigma_workbook_integration_tests._all_keys(spec, keys) %}
{% for k in keys %}
  {% do sigma_workbook_integration_tests._ok(not (k | string).startswith('_'), where ~ 'private key ' ~ k ~ ' leaked into the spec') %}
{% endfor %}
{% do sigma_workbook_integration_tests._ok('unresolved:' not in (spec | tojson), where ~ 'no unresolved data model id') %}
{% do sigma_workbook_integration_tests._ok('__color:' not in (spec | tojson), where ~ 'every late-bound color marker was resolved') %}

{# ---- pages ---- #}
{% for page in c.pages %}
  {% do sigma_workbook_integration_tests._ok(page.id and page.name, where ~ 'page has id and name') %}
  {% do sigma_workbook_integration_tests._ok(('<Page type="grid" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto" id="' ~ page.id ~ '"') in c.layout, where ~ 'layout has a <Page> for ' ~ page.name) %}
{% endfor %}

{# ---- elements: unique ids, columns ---- #}
{% set element_ids = [] %}
{% set column_ids = {} %}
{% for el in c.elements %}
  {% do sigma_workbook_integration_tests._ok(el.id not in element_ids, where ~ 'element id ' ~ el.id ~ ' is unique') %}
  {% do element_ids.append(el.id) %}
  {% do sigma_workbook_integration_tests._ok(el.kind, where ~ 'element ' ~ el.id ~ ' has a kind') %}
  {% set ids = [] %}
  {% for col in el.get('columns', []) %}
    {% do sigma_workbook_integration_tests._ok(col.id and col.formula, where ~ 'column has id and formula in ' ~ el.id) %}
    {% do sigma_workbook_integration_tests._ok(col.id not in ids, where ~ 'column id unique within ' ~ el.id) %}
    {% do ids.append(col.id) %}
  {% endfor %}
  {% do column_ids.update({el.id: ids}) %}
{% endfor %}

{# ---- per-kind required fields and internal references ---- #}
{% for el in c.elements %}
  {% set own = column_ids[el.id] %}
  {% set kind = el.kind %}
  {% if kind in ['table', 'kpi-chart', 'bar-chart', 'line-chart', 'area-chart', 'scatter-chart', 'pie-chart', 'donut-chart', 'pivot-table'] %}
    {% do sigma_workbook_integration_tests._ok(el.source and el.source.kind, where ~ kind ~ ' ' ~ el.id ~ ' has a source') %}
    {% if el.source.kind == 'table' %}
      {% do sigma_workbook_integration_tests._ok(el.source.elementId in element_ids, where ~ 'source.elementId of ' ~ el.id ~ ' exists') %}
    {% elif el.source.kind == 'warehouse-table' %}
      {% do sigma_workbook_integration_tests._ok(el.source.connectionId and el.source.path | length == 3, where ~ 'warehouse source of ' ~ el.id ~ ' has connectionId and a 3-part path') %}
    {% elif el.source.kind == 'data-model' %}
      {% do sigma_workbook_integration_tests._ok(el.source.dataModelId and el.source.elementId, where ~ 'data-model source of ' ~ el.id ~ ' has ids') %}
    {% endif %}
    {% do sigma_workbook_integration_tests._ok(own | length > 0, where ~ kind ~ ' ' ~ el.id ~ ' has columns') %}
  {% endif %}
  {% if kind == 'table' %}
    {% for oid in el.order %}
      {% do sigma_workbook_integration_tests._ok(oid in own, where ~ 'order entry ' ~ oid ~ ' is a column of ' ~ el.id) %}
    {% endfor %}
    {% for s in el.get('sort', []) %}
      {% do sigma_workbook_integration_tests._ok(s.columnId in own and s.direction in ['ascending', 'descending'], where ~ 'table sort is valid') %}
    {% endfor %}
  {% elif kind == 'kpi-chart' %}
    {% do sigma_workbook_integration_tests._ok(el.value.columnId in own, where ~ 'kpi value column exists') %}
  {% elif kind in ['bar-chart', 'line-chart', 'area-chart', 'scatter-chart'] %}
    {% do sigma_workbook_integration_tests._ok(el.xAxis.columnId in own, where ~ kind ~ ' xAxis column exists') %}
    {% for yid in el.yAxis.columnIds %}
      {% do sigma_workbook_integration_tests._ok(yid in own, where ~ kind ~ ' yAxis column exists') %}
    {% endfor %}
    {% if el.xAxis.get('sort') %}
      {% do sigma_workbook_integration_tests._ok(el.xAxis.sort.by in own and el.xAxis.sort.direction in ['ascending', 'descending'], where ~ kind ~ ' xAxis sort is valid') %}
    {% endif %}
    {% do sigma_workbook_integration_tests._ok(el.color.by in ['single', 'category', 'scale'], where ~ kind ~ ' color.by is a valid mode') %}
  {% elif kind in ['pie-chart', 'donut-chart'] %}
    {% do sigma_workbook_integration_tests._ok(el.color.columnId in own and el.value.columnId in own, where ~ kind ~ ' color/value columns exist') %}
  {% elif kind == 'pivot-table' %}
    {% for vid in el['values'] %}
      {% do sigma_workbook_integration_tests._ok(vid in own, where ~ 'pivot value column exists') %}
    {% endfor %}
    {% for level in el.get('rowsBy', []) + el.get('columnsBy', []) %}
      {% do sigma_workbook_integration_tests._ok(level.columnId in own, where ~ 'pivot grouping column exists') %}
    {% endfor %}
  {% elif kind == 'control' %}
    {% do sigma_workbook_integration_tests._ok(el.controlId and el.controlType, where ~ 'control has controlId and controlType') %}
    {% for f in el.filters %}
      {% do sigma_workbook_integration_tests._ok(f.source.kind == 'table' and f.source.elementId in element_ids, where ~ 'control ' ~ el.controlId ~ ' targets an existing element') %}
      {% do sigma_workbook_integration_tests._ok(f.columnId in column_ids[f.source.elementId], where ~ 'control ' ~ el.controlId ~ ' targets a column that exists on its element') %}
    {% endfor %}
    {% if el.controlType == 'list' %}
      {% do sigma_workbook_integration_tests._ok(el.source.source.elementId in element_ids and el.source.columnId in column_ids[el.source.source.elementId], where ~ 'list control ' ~ el.controlId ~ ' has a valid value source') %}
    {% endif %}
  {% elif kind == 'text' %}
    {% do sigma_workbook_integration_tests._ok(el.body, where ~ 'text has a body') %}
  {% endif %}

  {# every element is placed exactly once, containers as <GridContainer> #}
  {% set placed_as_leaf = ('<Element elementId="' ~ el.id ~ '"') in c.layout %}
  {% set placed_as_group = ('<Container elementId="' ~ el.id ~ '"') in c.layout %}
  {% do sigma_workbook_integration_tests._ok(placed_as_leaf or placed_as_group, where ~ 'element ' ~ el.id ~ ' (' ~ el.kind ~ ') appears in the layout') %}
  {% do sigma_workbook_integration_tests._ok((el.kind == 'container') == placed_as_group, where ~ 'only containers use <Container>') %}
{% endfor %}
{% endmacro %}


{% macro assert_workbooks() %}

{% for model_name in ['sigma_sales_dashboard', 'sigma_sales_simple', 'sigma_sales_from_data_model'] %}
  {% do sigma_workbook_integration_tests._check_workbook(model_name) %}
  {{ log('shape ok: ' ~ model_name, info=true) }}
{% endfor %}

{# ---- the full-primitives workbook: two pages, exact structure ---- #}
{% set dash = sigma_workbook_integration_tests._spec_of('sigma_sales_dashboard') %}
{% set dc = dash.contents %}
{% do sigma_workbook_integration_tests._ok(dc.pages | map(attribute='name') | list == ['Overview', 'Breakdown'], 'dashboard has Overview and Breakdown pages, in order') %}
{% do sigma_workbook_integration_tests._ok(dash.description == 'Integration-test workbook built from primitives', 'description is emitted') %}
{% set kinds = dc.elements | map(attribute='kind') | list %}
{% for expected in ['text', 'divider', 'container', 'kpi-chart', 'bar-chart', 'line-chart', 'donut-chart', 'pivot-table', 'table', 'control', 'button'] %}
  {% do sigma_workbook_integration_tests._ok(expected in kinds, 'dashboard contains a ' ~ expected) %}
{% endfor %}
{% set by_region = sigma_workbook_integration_tests._find(dc.elements, 'bar-chart', 'Revenue by region') %}
{% do sigma_workbook_integration_tests._ok(by_region.barStyle.cornerRadius == 'round' and by_region.gap.width == 'small' and by_region.dataLabel.labels == 'shown', 'extend() adds raw Sigma options while keeping the composed ones') %}
{% set button = sigma_workbook_integration_tests._find(dc.elements, 'button', none) %}
{% do sigma_workbook_integration_tests._ok(button.text == 'Open Sigma' and button.appearance == 'outline', 'raw() emits an unmodeled element kind with its properties') %}
{% set controls = dc.elements | selectattr('kind', 'equalto', 'control') | list %}
{% do sigma_workbook_integration_tests._ok(controls | length == 2, 'two controls in the dashboard') %}
{% do sigma_workbook_integration_tests._ok(controls[0].controlType == 'list' and controls[0].filters | length == 4, 'the Region list control filters four elements') %}
{% do sigma_workbook_integration_tests._ok(controls[1].controlType == 'date-range' and controls[1].mode == 'between', 'the date control is a between date-range') %}
{% set revenue = sigma_workbook_integration_tests._find(dc.elements, 'kpi-chart', 'Revenue') %}
{% do sigma_workbook_integration_tests._ok(revenue.comparisonColumn.columnId and revenue.comparison.display == 'percentage' and revenue.comparison.label == 'plan', 'KPI compare_to sets comparisonColumn + comparison') %}
{% do sigma_workbook_integration_tests._ok(revenue.columns[0].format.currencySymbol == '$', 'KPI value carries its currency format') %}
{% set orders_kpi = sigma_workbook_integration_tests._find(dc.elements, 'kpi-chart', 'Orders') %}
{% do sigma_workbook_integration_tests._ok(orders_kpi.periodComparison == 'month' and orders_kpi.timeline.columnId and orders_kpi.trend.shape == 'area', 'KPI timeline sets timeline + periodComparison + a sparkline') %}
{% set line = sigma_workbook_integration_tests._find(dc.elements, 'line-chart', none) %}
{% do sigma_workbook_integration_tests._ok(line.color.by == 'category' and line.xAxis.sort.direction == 'ascending', 'line chart colors by category and sorts the x axis ascending') %}
{# columns: formulas refer to columns unqualified and the element carries the qualified passthrough #}
{% set revenue_formulas = revenue.columns | map(attribute='formula') | list %}
{% do sigma_workbook_integration_tests._ok('Sum([Amount])' in revenue_formulas and '[stg_orders/Amount]' in revenue_formulas and '[stg_orders/Target Amount]' in revenue_formulas, 'a KPI over Sum([Amount]) also carries the [stg_orders/Amount] passthrough column (and one for its comparison)') %}
{% do sigma_workbook_integration_tests._ok(revenue.value.columnId != revenue.comparisonColumn.columnId, 'value and comparison are separate columns') %}
{% set donut_el = sigma_workbook_integration_tests._find(dc.elements, 'donut-chart', none) %}
{% do sigma_workbook_integration_tests._ok(donut_el.value.columnId != donut_el.holeValue.columnId, 'a donut whose hole shows the same measure gets a separate column for it (Sigma allows one channel per column)') %}
{# child element: an element source, with the parent element's columns referenced the way Sigma does #}
{% set child = sigma_workbook_integration_tests._find(dc.elements, 'bar-chart', 'Revenue by segment (from the table)') %}
{% set parent = sigma_workbook_integration_tests._find(dc.elements, 'table', 'Orders') %}
{% do sigma_workbook_integration_tests._ok(child.source.kind == 'table' and child.source.elementId == parent.id, 'a chart built on a table element sources from it') %}
{% set child_formulas = child.columns | map(attribute='formula') | list %}
{% do sigma_workbook_integration_tests._ok('[Orders/Segment]' in child_formulas, "the child qualifies the parent's columns with the parent element's name (Orders), not the underlying table's") %}
{% do sigma_workbook_integration_tests._ok('Sum([Revenue])' in child_formulas and '[Orders/Revenue]' in child_formulas, "the child reaches the parent's calculated column as [Parent/Column]") %}
{# a table must not end up with two columns of the same name: child references to it would be ambiguous #}
{% set visible_labels = [] %}
{% for col in parent.columns if not col.get('hidden') %}
  {% set label = col.name if col.get('name') else col.formula.split('/')[-1][:-1] %}
  {% do sigma_workbook_integration_tests._ok(label not in visible_labels, 'the table has two visible columns called ' ~ label) %}
  {% do visible_labels.append(label) %}
{% endfor %}
{% do sigma_workbook_integration_tests._ok(parent.columns | selectattr('hidden') | list | length > 0, 'columns added only to serve formulas or filters are hidden') %}
{% do sigma_workbook_integration_tests._ok(parent.order | length == parent.columns | rejectattr('hidden') | list | length, 'every visible table column is in the table order, and no hidden one is') %}
{% set control_ids = controls | map(attribute='controlId') | list %}
{% do sigma_workbook_integration_tests._ok(control_ids == ['region-control', 'order-date-control'], 'control ids default to <name>-control so they cannot collide with a column called ' ~ control_ids) %}
{# page membership is carried only by the layout: the Breakdown page holds the donut, not the line chart #}
{% set breakdown_xml = dc.layout.split('</Page>')[1] %}
{% set donut = sigma_workbook_integration_tests._find(dc.elements, 'donut-chart', none) %}
{% do sigma_workbook_integration_tests._ok(donut.id in breakdown_xml and line.id not in breakdown_xml, 'layout puts each element on the right page') %}

{# ---- simple_dashboard: several detail tables ---- #}
{% set simple = sigma_workbook_integration_tests._spec_of('sigma_sales_simple').contents %}
{% set simple_tables = simple.elements | selectattr('kind', 'equalto', 'table') | list %}
{% do sigma_workbook_integration_tests._ok(simple_tables | map(attribute='name') | list == ['Detail', 'Regional detail'], 'simple_dashboard emits table_columns first, then each entry of tables, in order') %}
{% do sigma_workbook_integration_tests._ok(simple_tables[1].sort[0].direction == 'descending', 'a table in tables keeps its sort') %}
{% set simple_controls = simple.elements | selectattr('kind', 'equalto', 'control') | list %}
{% for c in simple_controls %}
  {% set targeted = c.filters | map(attribute='source') | map(attribute='elementId') | list %}
  {% for t in simple_tables %}
    {% do sigma_workbook_integration_tests._ok(t.id in targeted, 'control ' ~ c.controlId ~ ' filters the table ' ~ t.name) %}
  {% endfor %}
{% endfor %}
{% set simple_xml_order = [] %}
{% for t in simple_tables %}{% do simple_xml_order.append(simple.layout.index(t.id)) %}{% endfor %}
{% do sigma_workbook_integration_tests._ok(simple_xml_order == simple_xml_order | sort, 'detail tables are laid out in the order given') %}

{# ---- theme: project var + per-workbook override + Sigma-blue default ---- #}
{% do sigma_workbook_integration_tests._ok(dc.settings.theme.overrides.colors.highlight == '#1A70F1', 'default primary is Sigma blue') %}
{% do sigma_workbook_integration_tests._ok(dc.settings.theme.overrides.categoricalScheme == 'superbloom', 'default categorical palette is superbloom') %}
{% set dm = sigma_workbook_integration_tests._spec_of('sigma_sales_from_data_model') %}
{% set dmc = dm.contents %}
{% do sigma_workbook_integration_tests._ok(dmc.settings.theme.overrides.colors.highlight == '#7008e7', 'workbook theme= override wins') %}
{% do sigma_workbook_integration_tests._ok(dmc.settings.theme.overrides.categoricalScheme == ['#7008e7', '#1A70F1', '#00786f'], 'a custom categorical palette is passed through') %}
{% do sigma_workbook_integration_tests._ok(dmc.settings.theme.overrides.colors.text == '#0a0a0a', 'un-overridden theme colors keep their defaults') %}
{% set bar = sigma_workbook_integration_tests._find(dmc.elements, 'bar-chart', 'Revenue by region') %}
{% do sigma_workbook_integration_tests._ok(bar.color.value == '#7008e7', 'single-series charts pick up the themed primary color') %}

{# ---- data model interop: the ids agree with sigma_data_models ---- #}
{% set model_spec = sigma_workbook_integration_tests._data_model_spec_of('sigma_sales_model') %}
{% set model_table_id = model_spec.pages[0].elements[0].id %}
{% do sigma_workbook_integration_tests._ok(bar.source.kind == 'data-model' and bar.source.elementId == model_table_id, 'workbook data-model source targets the exact table id sigma_data_models generated (' ~ model_table_id ~ ')') %}
{% do sigma_workbook_integration_tests._ok(bar.source.dataModelId == var('sigma_data_model_ids')['sigma_sales_model'], 'dataModelId comes from the sigma_data_model_ids var') %}
{% set placeholder = sigma_workbook.data_model('unresolved:x', 'orders', identifier='stg_orders') %}
{% do sigma_workbook_integration_tests._ok(placeholder.elementId == model_table_id, 'data_model() derives the same element id') %}
{% do sigma_workbook_integration_tests._ok(bar.columns[0].formula == '[Orders/Region]', 'columns read from a data model are prefixed with the data model table name') %}

{# ---- lineage: refs inside macros register as dependencies ---- #}
{% for node in graph.nodes.values() %}
  {% if node.resource_type == 'model' and node.name == 'sigma_sales_dashboard' %}
    {% do sigma_workbook_integration_tests._ok('model.sigma_workbook_integration_tests.stg_orders' in node.depends_on.nodes, 'from_ref() registers the model as a dependency') %}
  {% endif %}
  {% if node.resource_type == 'model' and node.name == 'sigma_sales_from_data_model' %}
    {% do sigma_workbook_integration_tests._ok('model.sigma_workbook_integration_tests.sigma_sales_model' in node.depends_on.nodes, 'from_data_model() registers the data model as a dependency') %}
  {% endif %}
{% endfor %}

{# ---- update by workbook_id, and number_range_control ---- #}
{% set src = sigma_workbook.from_ref('stg_orders') %}
{% set pages_for_format = [sigma_workbook.page('P', [sigma_workbook.text('hi', key='t')])] %}
{% set updating = sigma_workbook.workbook('Upd', pages_for_format, workbook_id='abc123') %}
{% do sigma_workbook_integration_tests._ok(updating.workbookId == 'abc123' and updating.contents.pages | length == 1, 'workbook_id is carried for updates') %}

{% do sigma_workbook_integration_tests._ok('<Element elementId=' in dc.layout and '<LayoutElement' not in dc.layout and '<Container elementId=' in dc.layout, 'the layout uses <Element>/<Container>, the only tags the current API accepts') %}
{% set nt = sigma_workbook.table(src, ['amount'], name='NT') %}
{% set nr = sigma_workbook.number_range_control('Amount', targets=[(nt, 'amount')], minimum=1, maximum=9) %}
{% do sigma_workbook_integration_tests._ok(nr.controlType == 'number-range' and nr.min == 1 and nr.max == 9 and nr.controlId == 'amount-control', 'number_range_control carries its bounds') %}

{# ---- determinism ---- #}
{% set a = sigma_workbook.simple_dashboard('Det', src, kpis=[{'value': 'Count()'}], charts=[{'type': 'bar', 'x': 'region', 'y': 'Count()', 'name': 'By region'}]) %}
{% set b = sigma_workbook.simple_dashboard('Det', src, kpis=[{'value': 'Count()'}], charts=[{'type': 'bar', 'x': 'region', 'y': 'Count()', 'name': 'By region'}]) %}
{% do sigma_workbook_integration_tests._ok((a | tojson) == (b | tojson), 'the same inputs compile to a byte-identical spec') %}
{% set c2 = sigma_workbook.simple_dashboard('Det2', src, kpis=[{'value': 'Count()'}]) %}
{% do sigma_workbook_integration_tests._ok(a.contents.pages[0].id != c2.contents.pages[0].id, 'different names produce different page ids') %}

{# ---- small units ---- #}
{% do sigma_workbook_integration_tests._ok(sigma_workbook.even_widths(3) == [8, 8, 8] and sigma_workbook.even_widths(4) == [6, 6, 6, 6] and sigma_workbook.even_widths(5) == [5, 5, 5, 5, 4], 'even_widths matches the 3/4/5-KPI band widths') %}
{% do sigma_workbook_integration_tests._ok(sigma_workbook.titleize('order_date') == 'Order Date' and sigma_workbook.titleize('ARR') == 'ARR', 'titleize title-cases snake_case but leaves mixed case alone') %}
{% do sigma_workbook_integration_tests._ok(sigma_workbook.formula_for('order_date', {'kind': 'warehouse-table', '_name': 'T'}) == '[T/Order Date]', 'bare column names get the source prefix') %}
{% do sigma_workbook_integration_tests._ok(sigma_workbook.formula_for('order_date', {'kind': 'table', '_name': 'Parent'}) == '[Parent/Order Date]', 'columns of a parent element are qualified with its name') %}
{% do sigma_workbook_integration_tests._ok(sigma_workbook.formula_for('Sum([Amount])', {'kind': 'warehouse-table', '_name': 'T'}) == 'Sum([Amount])', 'formulas are passed through untouched') %}
{% do sigma_workbook_integration_tests._ok(sigma_workbook.color('primary') == '#1A70F1' and sigma_workbook.color('#123456') == '#123456' and sigma_workbook.color('primary', {'colors': {'primary': '#000000'}}) == '#000000', 'color() resolves tokens, hex literals and overrides') %}
{% do sigma_workbook_integration_tests._ok(sigma_workbook.format_percent(2).formatString == '.2%' and sigma_workbook.format_date().kind == 'datetime', 'format helpers') %}
{% set placed = sigma_workbook.place([{'_w': 12, '_h': 4, '_key': 'a'}, {'_w': 12, '_h': 6, '_key': 'b'}, {'_w': 24, '_h': 3, '_key': 'c'}]) %}
{% do sigma_workbook_integration_tests._ok(placed['rows'] == 9 and placed['items'][2].row == 7 and placed['items'][1].col == 13, 'place() flows left to right and wraps below the tallest element') %}

{{ log('=== assert_workbooks: all assertions passed ===', info=true) }}
{% endmacro %}
