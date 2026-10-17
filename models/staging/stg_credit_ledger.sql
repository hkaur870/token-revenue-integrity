-- Credit movements: grant, purchase (positive); consumption, expiration (negative).
-- lot_id = 'unfunded' marks usage that was served with no credit left.
select
    entry_id, org_id,
    cast(entry_date as varchar)  as entry_date,
    entry_type,
    lot_id,
    cast(amount as double)       as amount
from {{ ref('raw_credit_ledger') }}
