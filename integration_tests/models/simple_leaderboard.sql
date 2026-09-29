{# A leaderboard: two dimensions ranked by one measure, plus a breakdown of the first. Nothing here is
   specific to the sample orders table; swap in any source, dimensions and measure. #}
{% set spec = sigma_workbook.simple_leaderboard(
    name='Leaderboard',
    source=sigma_workbook.from_ref('stg_orders'),
    dimensions=['region', 'segment'],
    measure='Sum([Amount])',
    measure_name='Total',
    kpis=[{'value': 'Sum([Amount])', 'name': 'Total', 'format': sigma_workbook.format_currency()}],
    detail_measures=['Count()', 'Avg([Amount])'],
    filters=[{'type': 'list', 'name': 'Segment', 'column': 'segment'}],
) %}

{{ sigma_workbook.materialize(spec) }}

select 1
