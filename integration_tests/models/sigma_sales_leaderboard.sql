{# A leaderboard: regions and segments ranked by revenue, plus a breakdown of the regions. #}
{% set spec = sigma_workbook.leaderboard(
    name='Sales leaderboard',
    source=sigma_workbook.from_ref('stg_orders'),
    dimensions=['region', 'segment'],
    measure='Sum([Amount])',
    measure_name='Revenue',
    kpis=[{'value': 'Sum([Amount])', 'name': 'Revenue', 'format': sigma_workbook.format_currency()}],
    detail_measures=['Count()', 'Avg([Amount])'],
    filters=[{'type': 'list', 'name': 'Segment', 'column': 'segment'}],
) %}

{{ sigma_workbook.materialize(spec) }}

select 1
