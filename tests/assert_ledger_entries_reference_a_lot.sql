-- Every credit movement points to a known lot ('unfunded' is reported separately).
select g.entry_id
from {{ ref('stg_credit_ledger') }} g
left join {{ ref('stg_credit_lots') }} l on l.lot_id = g.lot_id
where l.lot_id is null and g.lot_id <> 'unfunded'
