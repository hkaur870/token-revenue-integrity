-- line_item is a model id, 'web_search', or 'code_execution'.
select invoice_id, line_item, cast(line_amount as decimal(18, 2)) as line_amount
from {{ ref('raw_invoice_lines') }}
