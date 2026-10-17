-- Public list prices, USD per million tokens (see docs/sources.md).
select
    model,
    pricing_tier,                                           -- standard | fast | long_context
    cast(input_usd_per_mtok as double)          as input_price,
    cast(output_usd_per_mtok as double)         as output_price,
    cast(cache_write_5m_usd_per_mtok as double) as cache_write_5m_price,
    cast(cache_write_1h_usd_per_mtok as double) as cache_write_1h_price,
    cast(cache_hit_usd_per_mtok as double)      as cache_hit_price,
    cast(geo_eligible as integer) = 1           as geo_eligible
from {{ ref('raw_price_book') }}
