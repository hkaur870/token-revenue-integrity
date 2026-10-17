select
    subscription_id,
    plan,
    cast(billing_period as varchar)               as billing_period,
    cast(monthly_price_usd as double)             as monthly_price_usd,
    cast(api_equivalent_usage_usd as double)      as api_equivalent_usage_usd,
    cast(claude_code_share as double)             as claude_code_share
from {{ source('raw', 'subscriptions') }}
