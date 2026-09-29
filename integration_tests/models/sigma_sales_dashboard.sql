{# A workbook assembled from the primitives: every element is explicit, so this exercises the
   component library end to end. Two pages, a shared source, controls wired to several elements. #}
{% set orders = sigma_workbook.from_ref('stg_orders') %}

{% set detail = sigma_workbook.table(
    orders,
    ['order_id', 'order_date', 'region', 'segment',
     sigma_workbook.field('[Amount]', name='Revenue', format=sigma_workbook.format_currency(2))],
    name='Orders',
    key='orders_table',
    sort=[('order_date', 'desc')],
) %}

{% set revenue_kpi = sigma_workbook.kpi(orders, 'Sum([Amount])', name='Revenue',
    format=sigma_workbook.format_currency(), compare_to='Sum([Target Amount])', compare_label='plan') %}
{% set orders_kpi = sigma_workbook.kpi(orders, 'CountDistinct([Order Id])', name='Orders',
    format=sigma_workbook.format_number(), timeline='order_date', period='month', trend=true) %}
{% set avg_kpi = sigma_workbook.kpi(orders, 'Avg([Amount])', name='Average order',
    format=sigma_workbook.format_currency(2)) %}

{# extend() reaches any Sigma option the macros don't expose, without giving up the composed element #}
{% set by_region = sigma_workbook.extend(
    sigma_workbook.bar_chart(orders, 'region', 'Sum([Amount])', name='Revenue by region', labels=true),
    {'barStyle': {'cornerRadius': 'round'}, 'gap': {'width': 'small'}}) %}
{% set by_month = sigma_workbook.line_chart(orders, 'DateTrunc("month", [Order Date])', 'Sum([Amount])',
    color='segment', name='Revenue by month', sort_by='x') %}
{% set by_segment = sigma_workbook.donut_chart(orders, 'segment', 'Sum([Amount])', hole_value='Sum([Amount])', name='Revenue by segment') %}
{# a chart built on the table element above (Sigma's "child element"): it reads the table's columns, including the calculated Revenue #}
{% set child_chart = sigma_workbook.bar_chart(detail, 'segment', 'Sum([Revenue])', name='Revenue by segment (from the table)') %}
{% set heatmap = sigma_workbook.pivot_table(orders, 'Sum([Amount])', rows='region', cols='segment', name='Region x segment') %}

{% set region_filter = sigma_workbook.list_control('Region',
    targets=[(detail, 'region'), (revenue_kpi, 'region'), (by_region, 'region'), (by_month, 'region')]) %}
{% set date_filter = sigma_workbook.date_range_control('Order date',
    targets=[(detail, 'order_date'), (by_month, 'order_date')]) %}

{% set overview = sigma_workbook.page('Overview', [
    sigma_workbook.dashboard_header('Sales overview', 'Bookings against plan', [region_filter, date_filter]),
    sigma_workbook.kpi_row([revenue_kpi, orders_kpi, avg_kpi]),
    sigma_workbook.row([by_region, by_month], 'primary_charts'),
    sigma_workbook.text('Revenue is recognised on order date.', key='footnote'),
    sigma_workbook.divider('footnote_rule'),
    sigma_workbook.raw('button', 'open_sigma', {'text': 'Open Sigma', 'appearance': 'outline'}, w=4, h=2),
]) %}

{% set breakdown = sigma_workbook.page('Breakdown', [
    sigma_workbook.heading('Where the revenue comes from'),
    sigma_workbook.row([by_segment, heatmap], 'breakdown_row'),
    child_chart,
    detail,
]) %}

{% set spec = sigma_workbook.workbook(
    name='Sales dashboard',
    pages=[overview, breakdown],
    description='Integration-test workbook built from primitives',
) %}

{{ sigma_workbook.materialize(spec) }}

select 1
