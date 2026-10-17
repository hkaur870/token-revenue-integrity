-- Prepaid credit lots. Purchased credits expire one year after purchase; included subscriber
-- credits expire at the end of the month. opening_balance is the balance at period start.
select
    lot_id, org_id,
    lot_type,                                       -- purchased | included
    cast(acquired_on as varchar)                    as acquired_on,
    cast(expires_on as varchar)                     as expires_on,
    cast(original_amount as double)                 as original_amount,
    cast(opening_balance as double)                 as opening_balance
from {{ ref('raw_credit_lots') }}
