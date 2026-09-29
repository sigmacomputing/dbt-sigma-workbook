{# The package's design tokens. Every component that needs a color asks `sigma_workbook.color(token)`
   instead of hard-coding a hex, so one project var re-skins every workbook.

   Precedence, lowest to highest:
     1. these defaults (Sigma Blue + a neutral gray scale)
     2. the `sigma_workbook_theme` project var (dbt_project.yml -> vars)
     3. the `theme=` argument of `sigma_workbook.workbook()`

   Each level is deep-merged over the previous one, so overriding `colors.primary` keeps every
   other default. #}
{% macro default_theme() %}
{% do return({
  "name": "Light",
  "colors": {
    "primary": "#1A70F1",
    "text": "#0a0a0a",
    "body": "#525252",
    "muted": "#737373",
    "hairline": "#e5e5e5",
    "canvas": "#fafafa",
    "surface": "#ffffff",
    "success": "#008236",
    "warning": "#bb4d00",
    "danger": "#c10007",
  },
  "categorical": "superbloom",
  "sequential": none,
  "diverging": none,
  "fonts": {"text": none, "data": none},
  "page_width": "large",
  "cards": true,
}) %}
{% endmacro %}


{# The fully-resolved theme. Pass `override` to layer a per-workbook theme on top of the project var. #}
{% macro theme(override={}) %}
{% set merged = sigma_workbook.deep_merge(sigma_workbook.default_theme(), var('sigma_workbook_theme', {})) %}
{% do return(sigma_workbook.deep_merge(merged, override)) %}
{% endmacro %}


{# Resolves a design token to a hex string. Raises on an unknown token (a typo would otherwise
   silently emit `none` into the spec). A value that already looks like a hex color is passed
   through, so components can accept either a token or a literal. #}
{% macro color(token, override={}) %}
{% if token is none %}
  {% do return(none) %}
{% endif %}
{% if token.startswith('#') %}
  {% do return(token) %}
{% endif %}
{% set colors = sigma_workbook.theme(override)['colors'] %}
{% if token not in colors %}
  {% do sigma_workbook.fail('color', "unknown color token '" ~ token ~ "' - must be a hex value or one of " ~ (colors.keys() | list | sort)) %}
{% endif %}
{% do return(colors[token]) %}
{% endmacro %}


{# A late-bound color: element macros emit `__color:primary__` instead of a hex, and `workbook()` swaps
   every such marker for the color in the *final* theme (project var + the workbook's own `theme=`).
   That is why a workbook-level theme override recolors the elements too, even though the elements
   were built before `workbook()` was called. The token is validated now, so a typo fails at the
   line that wrote it. A hex value passes straight through. #}
{% macro color_ref(token) %}
{% if token is none %}
  {% do return(none) %}
{% endif %}
{% if token.startswith('#') %}
  {% do return(token) %}
{% endif %}
{% do sigma_workbook.color(token) %}
{% do return('__color:' ~ token ~ '__') %}
{% endmacro %}


{# Replaces every `__color:<token>__` marker anywhere in `value` with that token's hex in `colors`. #}
{% macro resolve_colors(value, colors) %}
{% if value is mapping %}
  {% set out = {} %}
  {% for k in value.keys() %}
    {% do out.update({k: sigma_workbook.resolve_colors(value[k], colors)}) %}
  {% endfor %}
  {% do return(out) %}
{% elif value is string %}
  {% if '__color:' in value %}
    {% set resolved = namespace(text=value) %}
    {% for token in colors.keys() %}
      {% set resolved.text = resolved.text.replace('__color:' ~ token ~ '__', colors[token]) %}
    {% endfor %}
    {% do return(resolved.text) %}
  {% endif %}
  {% do return(value) %}
{% elif value is sequence %}
  {% set out = [] %}
  {% for item in value %}
    {% do out.append(sigma_workbook.resolve_colors(item, colors)) %}
  {% endfor %}
  {% do return(out) %}
{% endif %}
{% do return(value) %}
{% endmacro %}


{# The theme as the `settings` block of a Sigma workbook spec. Only fields the user's theme actually
   sets are emitted (a `none` font, for instance, is left off so Sigma's default applies). #}
{% macro theme_settings(override={}) %}
{% set t = sigma_workbook.theme(override) %}
{% set c = t['colors'] %}
{% set overrides = {
  "colors": {
    "text": c['text'],
    "highlight": c['primary'],
    "surface": c['surface'],
    "success": c['success'],
    "warning": c['warning'],
    "danger": c['danger'],
  },
  "categoricalScheme": t['categorical'],
  "colorOverrides": [{"name": "backgroundCanvas", "color": c['canvas']}],
  "pageWidth": t['page_width'],
} %}
{% if t['sequential'] %}
  {% do overrides.update({"sequentialScheme": t['sequential']}) %}
{% endif %}
{% if t['diverging'] %}
  {% do overrides.update({"divergingScheme": t['diverging']}) %}
{% endif %}
{% set fonts = sigma_workbook.compact({"textFont": t['fonts']['text'], "dataFont": t['fonts']['data']}) %}
{% if fonts %}
  {% do overrides.update({"fonts": fonts}) %}
{% endif %}
{% do return({"theme": {"name": t['name'], "overrides": overrides}}) %}
{% endmacro %}
