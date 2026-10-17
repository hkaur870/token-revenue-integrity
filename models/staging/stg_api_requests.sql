select
    request_id,
    org_id,
    cast(request_ts as varchar)                   as request_ts,
    substr(cast(request_ts as varchar), 1, 10)    as usage_date,
    substr(cast(request_ts as varchar), 1, 7)     as usage_month,
    cast(substr(cast(request_ts as varchar), 12, 2) as integer) as usage_hour_utc,
    model,
    service_tier,                                 -- standard | batch | fast
    inference_geo,                                -- global | us
    status,                                       -- succeeded | failed (failed calls are not billed)
    cast(input_tokens as bigint)                  as input_tokens,
    cast(cache_write_5m_tokens as bigint)         as cache_write_5m_tokens,
    cast(cache_write_1h_tokens as bigint)         as cache_write_1h_tokens,
    cast(cache_read_tokens as bigint)             as cache_read_tokens,
    cast(output_tokens as bigint)                 as output_tokens,
    cast(web_search_requests as integer)          as web_search_requests,
    cast(web_search_failed as integer)            as web_search_failed,
    cast(code_exec_seconds as integer)            as code_exec_seconds,
    cast(ingested_at as varchar)                  as ingested_at
from {{ source('raw', 'api_requests') }}
