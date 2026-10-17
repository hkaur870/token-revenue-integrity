-- Does revenue booked in the general ledger match what was invoiced?
with inv as (
    select org_id, billing_period, sum(invoice_amount) as invoiced from {{ ref('stg_invoices') }} group by 1, 2
),
gl as (
    select org_id, billing_period, sum(revenue_amount) as booked from {{ ref('stg_gl_revenue') }} group by 1, 2
)
select
    coalesce(inv.org_id, gl.org_id) as org_id,
    coalesce(inv.billing_period, gl.billing_period) as billing_period,
    round(coalesce(inv.invoiced, 0), 2) as invoiced_amount,
    round(coalesce(gl.booked, 0), 2)    as booked_amount,
    round(coalesce(gl.booked, 0) - coalesce(inv.invoiced, 0), 2) as variance,
    case when abs(coalesce(gl.booked, 0) - coalesce(inv.invoiced, 0)) <= {{ var('tolerance') }}
         then 'matched' else 'mismatch' end as status
from inv
full outer join gl on gl.org_id = inv.org_id and gl.billing_period = inv.billing_period
