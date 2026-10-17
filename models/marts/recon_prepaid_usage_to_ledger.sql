-- Self-serve customers pay with prepaid credits. Did the credit ledger draw down exactly what
-- their usage was worth?
with usage as (
    select org_id, usage_month as billing_period, sum(token_amount + search_amount) as usage_usd
    from {{ ref('int_rated_requests') }}
    where segment = 'self_serve_prepaid'
    group by org_id, usage_month
),
consumed as (
    select org_id, substr(entry_date, 1, 7) as billing_period,
           -sum(amount) as consumed_usd,
           -sum(case when lot_id = 'unfunded' then amount else 0 end) as unfunded_usd
    from {{ ref('stg_credit_ledger') }}
    where entry_type = 'consumption'
    group by org_id, substr(entry_date, 1, 7)
)
select
    coalesce(u.org_id, c.org_id)                 as org_id,
    coalesce(u.billing_period, c.billing_period) as billing_period,
    round(coalesce(u.usage_usd, 0), 2)           as usage_usd,
    round(coalesce(c.consumed_usd, 0), 2)        as credits_consumed_usd,
    round(coalesce(c.unfunded_usd, 0), 2)        as unfunded_usage_usd,
    round(coalesce(c.consumed_usd, 0) - coalesce(u.usage_usd, 0), 2) as variance_usd,
    case when abs(coalesce(c.consumed_usd, 0) - coalesce(u.usage_usd, 0)) <= {{ var('tolerance') }}
         then 'matched' else 'mismatch' end      as status
from usage u
full outer join consumed c on c.org_id = u.org_id and c.billing_period = u.billing_period
