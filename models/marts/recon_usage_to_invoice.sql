-- Invoiced (enterprise) customers: did every dollar of usage reach the invoice at the right price?
-- Compares expected charges to invoice lines per org and line item, then tests each known billing
-- mistake to name the most likely cause of any mismatch.
with dup as (
    select r.request_id, d.copies - 1 as extra_copies
    from {{ ref('int_duplicate_requests') }} d
    join {{ ref('int_rated_requests') }} r on r.request_id = d.request_id
),
rated as (
    select r.*, coalesce(dup.extra_copies, 0) as extra_copies
    from {{ ref('int_rated_requests') }} r
    left join dup on dup.request_id = r.request_id
    where r.segment = 'enterprise_invoiced'
),
expected_lines as (
    select org_id, usage_month as billing_period, model as line_item,
           sum(token_amount)                                             as expected_amount,
           sum(case when is_late then token_amount else 0 end)           as late_amount,
           sum(token_amount * extra_copies)                              as duplicate_amount,
           sum(amount_if_cache_excluded_from_prompt_length)              as if_cache_excluded_from_prompt_length,
           sum(amount_if_geo_multiplier_missed)                          as if_geo_multiplier_missed,
           sum(amount_if_cache_hit_at_generic_rate)                      as if_cache_hit_at_generic_rate,
           sum(amount_if_batch_skips_cache)                              as if_batch_skips_cache,
           cast(null as double)                                          as if_failed_searches_billed,
           cast(null as double)                                          as if_free_hours_missed
    from rated
    group by org_id, usage_month, model
    union all
    select org_id, usage_month, 'web_search',
           sum(search_amount),
           sum(case when is_late then search_amount else 0 end),
           sum(search_amount * extra_copies),
           null, null, null, null,
           sum(search_amount_if_failed_billed),
           null
    from rated
    where web_search_requests > 0
    group by org_id, usage_month
    union all
    select c.org_id, c.billing_period, 'code_execution',
           c.expected_charge, 0, 0, null, null, null, null, null,
           c.charge_if_free_hours_missed
    from {{ ref('int_code_execution_monthly') }} c
    join {{ ref('stg_orgs') }} o on o.org_id = c.org_id
    where o.segment = 'enterprise_invoiced'
),
billed as (
    select i.org_id, i.billing_period, l.line_item, sum(l.line_amount) as billed_amount
    from {{ ref('stg_invoice_lines') }} l
    join {{ ref('stg_invoices') }} i on i.invoice_id = l.invoice_id
    group by i.org_id, i.billing_period, l.line_item
),
joined as (
    select
        coalesce(e.org_id, b.org_id)                  as org_id,
        coalesce(e.billing_period, b.billing_period)  as billing_period,
        coalesce(e.line_item, b.line_item)            as line_item,
        coalesce(e.expected_amount, 0)                as expected_amount,
        coalesce(b.billed_amount, 0)                  as billed_amount,
        coalesce(e.late_amount, 0)                    as late_amount,
        coalesce(e.duplicate_amount, 0)               as duplicate_amount,
        e.if_cache_excluded_from_prompt_length, e.if_geo_multiplier_missed,
        e.if_cache_hit_at_generic_rate, e.if_batch_skips_cache,
        e.if_failed_searches_billed, e.if_free_hours_missed
    from expected_lines e
    full outer join billed b
      on b.org_id = e.org_id and b.billing_period = e.billing_period and b.line_item = e.line_item
),
classified as (
    select *,
        billed_amount - expected_amount as variance,
        case when abs(billed_amount - expected_amount) <= {{ var('tolerance') }} then 'matched'
             when billed_amount = 0 then 'not_invoiced'
             when billed_amount < expected_amount then 'under_billed'
             else 'over_billed' end as status
    from joined
)
select
    org_id, billing_period, line_item,
    round(expected_amount, 2) as expected_amount,
    round(billed_amount, 2)   as billed_amount,
    round(variance, 2)        as variance,
    status,
    case
        when status = 'matched' then null
        {% set t = var('tolerance') %}
        when late_amount > 0 and abs(billed_amount - (expected_amount - late_amount)) <= {{ t }}
            then 'late_usage_missed_billing_run'
        when duplicate_amount > 0 and abs(billed_amount - (expected_amount + duplicate_amount)) <= {{ t }}
            then 'duplicate_requests_billed'
        when abs(if_cache_excluded_from_prompt_length - expected_amount) > {{ t }}
         and abs(billed_amount - if_cache_excluded_from_prompt_length) <= {{ t }}
            then 'long_context_tier_missed_cache_tokens_excluded'
        when abs(if_geo_multiplier_missed - expected_amount) > {{ t }}
         and abs(billed_amount - if_geo_multiplier_missed) <= {{ t }}
            then 'us_inference_geo_multiplier_missed'
        when abs(if_cache_hit_at_generic_rate - expected_amount) > {{ t }}
         and abs(billed_amount - if_cache_hit_at_generic_rate) <= {{ t }}
            then 'cache_hits_billed_at_generic_0_1x'
        when abs(if_batch_skips_cache - expected_amount) > {{ t }}
         and abs(billed_amount - if_batch_skips_cache) <= {{ t }}
            then 'batch_discount_not_applied_to_cache'
        when abs(if_failed_searches_billed - expected_amount) > {{ t }}
         and abs(billed_amount - if_failed_searches_billed) <= {{ t }}
            then 'failed_web_searches_billed'
        when abs(if_free_hours_missed - expected_amount) > {{ t }}
         and abs(billed_amount - if_free_hours_missed) <= {{ t }}
            then 'code_execution_free_hours_missed'
        else 'unexplained'
    end as likely_cause
from classified
