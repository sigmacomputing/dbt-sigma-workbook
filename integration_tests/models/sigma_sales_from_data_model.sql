{# A workbook whose data comes from a Sigma data model (composed by sigma_sales_model) rather than
   straight from the warehouse. `identifier` mirrors the relation the data model's table was bound to. #}
{% set sales = sigma_workbook.from_data_model('sigma_sales_model', 'orders', identifier='stg_orders') %}

{% set spec = sigma_workbook.workbook(
    name='Sales from the data model',
    pages=[sigma_workbook.page('Overview', [
      sigma_workbook.title('Sales (governed)', 'Reads the Sales Model data model'),
      sigma_workbook.kpi_row([
        sigma_workbook.kpi(sales, 'Sum([Amount])', name='Revenue', format=sigma_workbook.format_currency()),
        sigma_workbook.kpi(sales, 'Count()', name='Orders'),
      ]),
      sigma_workbook.bar_chart(sales, 'region', 'Sum([Amount])', name='Revenue by region', w=24),
    ])],
    theme={'colors': {'primary': '#7008e7'}, 'categorical': ['#7008e7', '#1A70F1', '#00786f']},
) %}

{{ sigma_workbook.materialize(spec) }}

select 1
