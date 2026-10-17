{{ config(materialized='incremental', unique_key='request_id') }}

-- Rates every successful request at public list prices: the amount the customer SHOULD pay.
-- Also prices each request under common billing mistakes ("what-if" amounts) so that any
-- invoice mismatch can be traced to its most likely cause, and splits out each pricing lever.
-- Incremental: each run only rates requests ingested since the last run.
with req as (
    select
        r.*,
        o.segment,
        o.channel,
        r.input_tokens + r.cache_write_5m_tokens + r.cache_write_1h_tokens + r.cache_read_tokens as prompt_tokens
    from {{ ref('int_requests_deduped') }} r
    join {{ ref('stg_orgs') }} o on o.org_id = r.org_id
    where r.status = 'succeeded'
    {% if is_incremental() %}
      and r.ingested_at > (select max(ingested_at) from {{ this }})
    {% endif %}
),
tiered as (
    select
        *,
        case when service_tier = 'fast' then 'fast'
             when model = 'claude-haiku-5-5' and prompt_tokens > {{ var('haiku_long_prompt_threshold') }} then 'long_context'
             else 'standard' end as pricing_tier,
        -- the tier a system would pick if it measured prompt length WITHOUT cache tokens
        case when service_tier = 'fast' then 'fast'
             when model = 'claude-haiku-5-5' and input_tokens > {{ var('haiku_long_prompt_threshold') }} then 'long_context'
             else 'standard' end as pricing_tier_if_cache_excluded,
        case when service_tier = 'batch' then {{ var('batch_multiplier') }} else 1.0 end as batch_mult
    from req
),
priced as (
    select
        t.*,
        case when t.inference_geo = 'us' and p.geo_eligible then {{ var('us_geo_multiplier') }} else 1.0 end as geo_mult,
        p.input_price, p.output_price, p.cache_write_5m_price, p.cache_write_1h_price, p.cache_hit_price,
        q.input_price  as q_input_price,  q.output_price as q_output_price,
        q.cache_write_5m_price as q_cw5_price, q.cache_write_1h_price as q_cw1_price, q.cache_hit_price as q_hit_price,
        s.input_price  as s_input_price,  s.output_price as s_output_price,
        s.cache_write_5m_price as s_cw5_price, s.cache_write_1h_price as s_cw1_price, s.cache_hit_price as s_hit_price
    from tiered t
    join {{ ref('stg_price_book') }} p on p.model = t.model and p.pricing_tier = t.pricing_tier
    join {{ ref('stg_price_book') }} q on q.model = t.model and q.pricing_tier = t.pricing_tier_if_cache_excluded
    join {{ ref('stg_price_book') }} s on s.model = t.model and s.pricing_tier = 'standard'
),
components as (
    select
        *,
        (input_tokens * input_price + output_tokens * output_price) / 1000000.0             as io_usd,
        (cache_write_5m_tokens * cache_write_5m_price + cache_write_1h_tokens * cache_write_1h_price
          + cache_read_tokens * cache_hit_price) / 1000000.0                                  as cache_usd
    from priced
)
select
    request_id, org_id, segment, channel, request_ts, usage_date, usage_month, usage_hour_utc,
    model, service_tier, pricing_tier, inference_geo, ingested_at,
    input_tokens, cache_write_5m_tokens, cache_write_1h_tokens, cache_read_tokens, output_tokens, prompt_tokens,
    web_search_requests, web_search_failed, code_exec_seconds,

    -- what the customer should pay
    geo_mult * batch_mult * (io_usd + cache_usd)                                      as token_amount,
    (web_search_requests - web_search_failed) * {{ var('web_search_usd') }}           as search_amount,
    case when code_exec_seconds > 0 and code_exec_seconds < {{ var('code_min_seconds') }}
         then {{ var('code_min_seconds') }} else code_exec_seconds end                as code_billable_seconds,

    -- what-if amounts for root-cause diagnosis
    geo_mult * batch_mult * (
        (input_tokens * q_input_price + output_tokens * q_output_price
         + cache_write_5m_tokens * q_cw5_price + cache_write_1h_tokens * q_cw1_price
         + cache_read_tokens * q_hit_price) / 1000000.0)                              as amount_if_cache_excluded_from_prompt_length,
    batch_mult * (io_usd + cache_usd)                                                 as amount_if_geo_multiplier_missed,
    geo_mult * batch_mult * (io_usd + (cache_write_5m_tokens * cache_write_5m_price
        + cache_write_1h_tokens * cache_write_1h_price
        + cache_read_tokens * 0.1 * input_price) / 1000000.0)                         as amount_if_cache_hit_at_generic_rate,
    geo_mult * (batch_mult * io_usd + cache_usd)                                      as amount_if_batch_skips_cache,
    web_search_requests * {{ var('web_search_usd') }}                                 as search_amount_if_failed_billed,

    -- pricing levers (for revenue-mix analysis)
    geo_mult * (io_usd + cache_usd)                                                   as amount_before_batch_discount,
    batch_mult * (io_usd + cache_usd)                                                 as amount_before_geo_uplift,
    geo_mult * batch_mult * ((input_tokens * s_input_price + output_tokens * s_output_price
        + cache_write_5m_tokens * s_cw5_price + cache_write_1h_tokens * s_cw1_price
        + cache_read_tokens * s_hit_price) / 1000000.0)                               as amount_at_standard_tier,
    geo_mult * batch_mult * cache_read_tokens * (input_price - cache_hit_price) / 1000000.0 as cache_hit_savings,

    ingested_at > '{{ var("billing_cutoff") }}'                                       as is_late,
    usage_date = usage_month || '-01' and usage_hour_utc < {{ var('partner_utc_offset_hours') }} as is_in_partner_prior_period
from components
