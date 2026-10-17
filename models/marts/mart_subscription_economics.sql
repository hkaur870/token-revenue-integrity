-- Flat-rate Claude plans vs. the API list-price value of the usage they include.
-- A ratio above 1.0 means a subscriber used more than their plan price at API rates.
with s as (
    select *,
        api_equivalent_usage_usd / monthly_price_usd as usage_to_price_ratio,
        row_number() over (partition by plan order by api_equivalent_usage_usd / monthly_price_usd) as rn,
        count(*) over (partition by plan) as n,
        ntile(20) over (partition by plan order by api_equivalent_usage_usd desc) as usage_vigintile
    from {{ ref('stg_subscriptions') }}
)
select
    plan,
    max(monthly_price_usd)                                       as monthly_price_usd,
    count(*)                                                     as subscribers,
    round(sum(monthly_price_usd), 2)                             as subscription_revenue_usd,
    round(sum(api_equivalent_usage_usd), 2)                      as api_equivalent_usage_usd,
    round(sum(api_equivalent_usage_usd) / sum(monthly_price_usd), 2) as aggregate_usage_to_price,
    round(max(case when rn = cast(0.5 * n as integer) then usage_to_price_ratio end), 2)  as median_ratio,
    round(max(case when rn = cast(0.95 * n as integer) then usage_to_price_ratio end), 2) as p95_ratio,
    round(100.0 * sum(case when usage_to_price_ratio > 1 then 1 else 0 end) / count(*), 1) as pct_above_1x,
    round(100.0 * sum(case when usage_to_price_ratio > 5 then 1 else 0 end) / count(*), 1) as pct_above_5x,
    round(100.0 * sum(case when usage_vigintile = 1 then api_equivalent_usage_usd else 0 end)
          / sum(api_equivalent_usage_usd), 1)                    as top_5pct_share_of_usage,
    round(avg(claude_code_share), 3)                             as avg_claude_code_share
from s
group by plan
