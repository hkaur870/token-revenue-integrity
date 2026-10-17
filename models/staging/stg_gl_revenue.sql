select
    journal_entry_id, org_id,
    cast(billing_period as varchar)         as billing_period,
    cast(revenue_amount as decimal(18, 2))  as revenue_amount
from {{ ref('raw_gl_revenue') }}
