-- Was every invoice collected?
with paid as (
    select invoice_id, sum(payment_amount) as amount_paid
    from {{ ref('stg_payments') }} where status = 'succeeded' group by invoice_id
)
select
    i.invoice_id, i.org_id, i.billing_period, i.due_date, i.invoice_amount,
    round(coalesce(p.amount_paid, 0), 2)                    as amount_paid,
    round(i.invoice_amount - coalesce(p.amount_paid, 0), 2) as open_balance,
    case when coalesce(p.amount_paid, 0) = 0 then 'unpaid'
         when i.invoice_amount - p.amount_paid > {{ var('tolerance') }} then 'partially_paid'
         when p.amount_paid - i.invoice_amount > {{ var('tolerance') }} then 'overpaid'
         else 'paid' end                                    as status,
    case when i.due_date < '{{ var("as_of_date") }}'
          and i.invoice_amount - coalesce(p.amount_paid, 0) > {{ var('tolerance') }}
         then true else false end                           as is_past_due
from {{ ref('stg_invoices') }} i
left join paid p on p.invoice_id = i.invoice_id
