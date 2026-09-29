{# Layout: turns a list of elements into positions on Sigma's 24-column page grid, and the grid into
   the XML string Sigma expects in a workbook's `layout` field.

   Placement is a simple left-to-right flow: each element sits to the right of the previous one until
   it would overflow the 24 columns, then wraps to a new row below the tallest element so far. That
   is enough for dashboards - a title, a KPI band, a chart row, a table - without hand-placing
   anything. Each element's footprint comes from its `w=` / `h=` arguments (every element macro has
   a sensible default).

   The XML vocabulary differs between the two generations of Sigma's API (see `workbook()`):

     contents (POST /v2/workbooks)   <Page> holding <Element> and <Container>
     spec     (POST /v2/workbooks/spec, deprecated)   <Page> holding <LayoutElement> and <GridContainer>

   The current endpoint rejects the legacy names ("unknown element <LayoutElement> ... expected
   Element, Container, or TabbedContainer"). #}


{# Returns {'items': [{'element', 'col', 'row', 'w', 'h'}, ...], 'rows': total_height}. Columns and rows
   are 1-based grid lines' start positions, as in CSS grid. #}
{% macro place(elements, columns=24) %}
{% set state = namespace(col=1, row=1, band=0) %}
{% set items = [] %}
{% for el in elements %}
  {% set w = el['_w'] %}
  {% set h = el['_h'] %}
  {% if w > columns %}
    {% do sigma_workbook.fail('layout', "element '" ~ el['_key'] ~ "' is " ~ w ~ " columns wide but the grid has " ~ columns ~ ".") %}
  {% endif %}
  {% if state.col + w - 1 > columns %}
    {% set state.row = state.row + state.band %}
    {% set state.col = 1 %}
    {% set state.band = 0 %}
  {% endif %}
  {% do items.append({"element": el, "col": state.col, "row": state.row, "w": w, "h": h}) %}
  {% set state.col = state.col + w %}
  {% set state.band = [state.band, h] | max %}
{% endfor %}
{% do return({"items": items, "rows": state.row + state.band - 1}) %}
{% endmacro %}


{# The XML for a list of placed items. Containers nest their children; everything else is a leaf.
   `indent` is the current nesting depth; `output` selects the tag vocabulary. #}
{% macro layout_items_xml(items, indent, output) %}
{% set pad = '  ' * indent %}
{% set leaf_tag = 'LayoutElement' if output == 'spec' else 'Element' %}
{% set group_tag = 'GridContainer' if output == 'spec' else 'Container' %}
{% set lines = [] %}
{% for item in items %}
  {% set el = item['element'] %}
  {% set position = 'gridColumn="' ~ item['col'] ~ ' / ' ~ (item['col'] + item['w']) ~ '" gridRow="' ~ item['row'] ~ ' / ' ~ (item['row'] + item['h']) ~ '"' %}
  {% if el.get('_children') %}
    {% set inner = sigma_workbook.place(el['_children']) %}
    {% do lines.append(pad ~ '<' ~ group_tag ~ ' elementId="' ~ el['id'] ~ '" type="grid" ' ~ position ~ ' gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto">') %}
    {% do lines.append(sigma_workbook.layout_items_xml(inner['items'], indent + 1, output)) %}
    {% do lines.append(pad ~ '</' ~ group_tag ~ '>') %}
  {% else %}
    {% do lines.append(pad ~ '<' ~ leaf_tag ~ ' elementId="' ~ el['id'] ~ '" ' ~ position ~ '/>') %}
  {% endif %}
{% endfor %}
{% do return(lines | join('\n')) %}
{% endmacro %}


{# One page's <Page> node. #}
{% macro page_layout_xml(page_id, elements, output) %}
{% set placed = sigma_workbook.place(elements) %}
{% set header = '<Page type="grid" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto" id="' ~ page_id ~ '">' %}
{% do return(header ~ '\n' ~ sigma_workbook.layout_items_xml(placed['items'], 1, output) ~ '\n</Page>') %}
{% endmacro %}
