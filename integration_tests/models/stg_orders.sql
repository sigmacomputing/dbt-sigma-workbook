select
    order_id,
    cast(order_date as date) as order_date,
    region,
    segment,
    amount,
    target_amount
from {{ ref('orders') }}
