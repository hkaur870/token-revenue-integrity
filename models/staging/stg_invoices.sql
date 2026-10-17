select
    invoice_id, org_id,
    cast(billing_period as varchar)         as billing_period,
    cast(invoice_date as varchar)           as invoice_date,
    cast(due_date as varchar)               as due_date,
    cast(invoice_amount as decimal(18, 2))  as invoice_amount
from {{ ref('raw_invoices') }}
