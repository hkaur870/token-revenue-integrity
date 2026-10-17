-- How much each pricing lever moved revenue this month, versus list price without it.
-- Negative = discount given to customers; positive = premium earned.
select 'Batch API discount (50%)' as lever,
       round(-sum(amount_before_batch_discount - token_amount), 2) as revenue_effect_usd,
       sum(case when service_tier = 'batch' then 1 else 0 end) as requests_affected
from {{ ref('int_rated_requests') }}
union all
select 'Prompt caching (cache hits vs. fresh input)',
       round(-sum(cache_hit_savings), 2),
       sum(case when cache_read_tokens > 0 then 1 else 0 end)
from {{ ref('int_rated_requests') }}
union all
select 'US-only inference (1.1x)',
       round(sum(token_amount - amount_before_geo_uplift), 2),
       sum(case when inference_geo = 'us' then 1 else 0 end)
from {{ ref('int_rated_requests') }}
union all
select 'Fast mode premium',
       round(sum(case when pricing_tier = 'fast' then token_amount - amount_at_standard_tier else 0 end), 2),
       sum(case when pricing_tier = 'fast' then 1 else 0 end)
from {{ ref('int_rated_requests') }}
union all
select 'Haiku 5.5 long-prompt pricing (>100k tokens)',
       round(sum(case when pricing_tier = 'long_context' then token_amount - amount_at_standard_tier else 0 end), 2),
       sum(case when pricing_tier = 'long_context' then 1 else 0 end)
from {{ ref('int_rated_requests') }}
