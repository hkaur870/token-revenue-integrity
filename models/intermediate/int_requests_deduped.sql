-- One copy of each request. Duplicates (metering retries) are reported in billing_exceptions.
with ranked as (
    select *, row_number() over (partition by request_id order by ingested_at) as copy_number
    from {{ ref('stg_api_requests') }}
)
select * from ranked where copy_number = 1
