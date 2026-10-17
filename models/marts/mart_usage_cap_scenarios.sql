-- What-if: cap each subscriber's monthly usage at N times their plan price (at API list rates).
-- Shows how few subscribers a cap touches and how much usage it removes.
with caps as (
    select 3 as cap_multiple union all select 5 union all select 10 union all select 20
)
select
    c.cap_multiple,
    count(*)                                                                  as subscribers,
    sum(case when s.api_equivalent_usage_usd > c.cap_multiple * s.monthly_price_usd then 1 else 0 end) as subscribers_capped,
    round(100.0 * sum(case when s.api_equivalent_usage_usd > c.cap_multiple * s.monthly_price_usd then 1 else 0 end)
          / count(*), 2)                                                      as pct_subscribers_capped,
    round(sum(case when s.api_equivalent_usage_usd > c.cap_multiple * s.monthly_price_usd
                   then s.api_equivalent_usage_usd - c.cap_multiple * s.monthly_price_usd else 0 end), 2) as usage_removed_usd,
    round(100.0 * sum(case when s.api_equivalent_usage_usd > c.cap_multiple * s.monthly_price_usd
                   then s.api_equivalent_usage_usd - c.cap_multiple * s.monthly_price_usd else 0 end)
          / sum(s.api_equivalent_usage_usd), 1)                               as pct_usage_removed
from caps c
cross join {{ ref('stg_subscriptions') }} s
group by c.cap_multiple
