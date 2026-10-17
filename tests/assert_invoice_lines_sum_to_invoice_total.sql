-- Every invoice header equals the sum of its lines.
select i.invoice_id
from {{ ref('stg_invoices') }} i
join {{ ref('stg_invoice_lines') }} l on l.invoice_id = i.invoice_id
group by i.invoice_id, i.invoice_amount
having abs(i.invoice_amount - sum(l.line_amount)) > {{ var('tolerance') }}
