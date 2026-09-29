{# Text, page titles and dividers: the non-data elements. #}

{# A markdown text element. `body` supports Sigma's markdown plus inline HTML spans. #}
{% macro text(body, key=none, w=24, h=2, align='top') %}
{% set el = sigma_workbook.new_element('text', 'text', key, body, w, h) %}
{% do el.update({"body": body, "verticalAlign": align}) %}
{% do return(el) %}
{% endmacro %}


{# A page heading: a level-1 title, with an optional muted subtitle underneath. #}
{% macro title(text, subtitle=none, key=none, w=24, h=3) %}
{% set body = '# ' ~ text %}
{% if subtitle %}
  {% set body = body ~ '\n\n<span style="color: ' ~ sigma_workbook.color_ref('muted') ~ '">' ~ subtitle ~ '</span>' %}
{% endif %}
{% do return(sigma_workbook.text(body, key=key or ('title:' ~ text), w=w, h=h, align='center')) %}
{% endmacro %}


{# A section heading, one step below `title`. #}
{% macro heading(text, key=none, w=24, h=2) %}
{% do return(sigma_workbook.text('### ' ~ text, key=key or ('heading:' ~ text), w=w, h=h, align='center')) %}
{% endmacro %}


{# A rule between sections. Give repeated dividers distinct keys. #}
{% macro divider(key='divider', direction='horizontal', w=24, h=1) %}
{% set el = sigma_workbook.new_element('divider', 'divider', key, none, w, h) %}
{% do el.update({
  "direction": direction,
  "style": {"color": sigma_workbook.color_ref('hairline'), "width": 1, "strokeStyle": "solid"},
}) %}
{% do return(el) %}
{% endmacro %}
