{# A multi-page report. Both pages have a "Revenue" KPI and a "Region" filter; the page-scoped keys and
   control ids are what keep them apart. #}
{% set spec = sigma_workbook.report(
    name='Sales report',
    source=sigma_workbook.from_ref('stg_orders'),
    pages=[
      {
        'name': 'Overview',
        'subtitle': 'Where we stand',
        'kpis': [
          {'value': 'Sum([Amount])', 'name': 'Revenue', 'format': sigma_workbook.format_currency()},
          {'value': 'Count()', 'name': 'Orders'},
        ],
        'charts': [{'type': 'line', 'x': 'DateTrunc("month", [Order Date])', 'y': 'Sum([Amount])', 'name': 'Revenue by month', 'sort_by': 'x'}],
        'filters': [{'type': 'list', 'name': 'Region', 'column': 'region'}],
      },
      {
        'name': 'Detail',
        'kpis': [{'value': 'Sum([Amount])', 'name': 'Revenue'}],
        'table_columns': ['order_id', 'order_date', 'region', 'segment', 'amount'],
        'table_name': 'Orders',
        'filters': [
          {'type': 'list', 'name': 'Region', 'column': 'region'},
          {'type': 'text', 'name': 'Order', 'column': 'order_id'},
        ],
      },
    ],
) %}

{{ sigma_workbook.materialize(spec) }}

select 1
