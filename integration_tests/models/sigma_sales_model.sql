{# A Sigma data model, composed with the companion `sigma_data_models` package. The workbooks below
   read from its `orders` table without repeating any column definitions. #}
{% set sigma_data_model = sigma_data_models.model(
    name='Sales Model',
    tables=[
      sigma_data_models.table('orders', 'stg_orders',
        columns=['order_id', 'order_date', 'region', 'segment', 'amount', 'target_amount']),
    ],
) %}

{{ sigma_data_models.materialize(sigma_data_model) }}

select 1
