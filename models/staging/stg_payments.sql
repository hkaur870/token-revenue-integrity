select
    payment_id, invoice_id, org_id,
    cast(payment_date as varchar)           as payment_date,
    cast(payment_amount as decimal(18, 2))  as payment_amount,
    status
from {{ ref('raw_payments') }}
