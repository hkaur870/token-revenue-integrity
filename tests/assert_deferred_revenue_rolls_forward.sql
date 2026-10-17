-- opening + added - recognized - breakage must equal closing for each credit type.
select lot_type
from {{ ref('deferred_revenue_rollforward') }}
where abs(opening_balance + purchases_or_grants - recognized_from_usage - expired_breakage - closing_balance) > 1
