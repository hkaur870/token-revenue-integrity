-- Claude Platform on AWS and Microsoft Foundry bill customers in arrears in Claude Consumption
-- Units (CCUs, $0.01 each). Does each partner's settlement match our own metered usage?
with expected as (
    select org_id, channel, usage_month as billing_period,
           sum(token_amount + search_amount)                                                as expected_usd,
           sum(case when is_in_partner_prior_period then token_amount + search_amount else 0 end) as first_hours_usd
    from {{ ref('int_rated_requests') }}
    where segment = 'cloud_marketplace'
    group by org_id, channel, usage_month
)
select
    coalesce(e.org_id, s.org_id)                   as org_id,
    coalesce(e.channel, s.channel)                 as channel,
    coalesce(e.billing_period, s.billing_period)   as billing_period,
    round(coalesce(e.expected_usd, 0) / {{ var('ccu_usd') }}, 0) as expected_ccus,
    coalesce(s.ccus_billed, 0)                     as settled_ccus,
    round(coalesce(e.expected_usd, 0), 2)          as expected_usd,
    coalesce(s.settlement_amount_usd, 0)           as settled_usd,
    round(coalesce(s.settlement_amount_usd, 0) - coalesce(e.expected_usd, 0), 2) as variance_usd,
    case when abs(coalesce(s.settlement_amount_usd, 0) - coalesce(e.expected_usd, 0)) <= {{ var('tolerance') }}
         then 'matched' else 'mismatch' end        as status,
    case
        when abs(coalesce(s.settlement_amount_usd, 0) - coalesce(e.expected_usd, 0)) <= {{ var('tolerance') }} then null
        when e.first_hours_usd > 0
         and abs(s.settlement_amount_usd - (e.expected_usd - e.first_hours_usd)) <= {{ var('tolerance') }}
            then 'partner_month_cutoff_in_pacific_time'
        when s.org_id is null then 'settlement_missing'
        else 'unexplained'
    end as likely_cause
from expected e
full outer join {{ ref('stg_partner_settlements') }} s
  on s.org_id = e.org_id and s.billing_period = e.billing_period
