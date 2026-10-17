-- Top-line revenue integrity for the period.
with usage as (
    select usage_month as billing_period, count(*) as requests,
           sum(token_amount + search_amount) as rated_usage_usd,
           sum(prompt_tokens + output_tokens) as total_tokens
    from {{ ref('int_rated_requests') }} group by usage_month
),
inv as (
    select billing_period, sum(invoice_amount) as invoiced, sum(amount_paid) as collected,
           sum(case when open_balance > 0 then open_balance else 0 end) as open_receivables
    from {{ ref('recon_invoice_to_payment') }} group by billing_period
),
exc as (
    select
        sum(case when direction = 'leakage' and domain in ('invoicing', 'partner_channel', 'prepaid_credits')
                 then amount_at_risk else 0 end) as revenue_leakage,
        sum(case when direction = 'overcharge' then amount_at_risk else 0 end) as customer_overcharges,
        sum(case when domain = 'collections' then amount_at_risk else 0 end) as collections_at_risk,
        count(*) as exceptions,
        sum(amount_at_risk) as total_at_risk
    from {{ ref('billing_exceptions') }}
),
dr as (
    select sum(case when lot_type = 'purchased' then closing_balance else 0 end) as deferred_revenue_closing,
           sum(case when lot_type = 'purchased' then expired_breakage else 0 end) as breakage
    from {{ ref('deferred_revenue_rollforward') }}
)
select
    u.billing_period,
    u.requests,
    u.total_tokens,
    round(u.rated_usage_usd, 2)          as rated_usage_usd,
    round(i.invoiced, 2)                 as invoiced_usd,
    round(i.collected, 2)                as collected_usd,
    round(i.open_receivables, 2)         as open_receivables_usd,
    round(dr.deferred_revenue_closing, 2) as deferred_revenue_closing_usd,
    round(dr.breakage, 2)                as breakage_usd,
    round(exc.revenue_leakage, 2)        as revenue_leakage_usd,
    round(exc.customer_overcharges, 2)   as customer_overcharges_usd,
    round(exc.collections_at_risk, 2)    as collections_at_risk_usd,
    round(10000.0 * exc.revenue_leakage / u.rated_usage_usd, 1)      as leakage_bps_of_usage,
    round(10000.0 * exc.customer_overcharges / u.rated_usage_usd, 1) as overcharge_bps_of_usage,
    exc.exceptions                       as exception_count,
    round(exc.total_at_risk, 2)          as total_at_risk_usd
from usage u
left join inv i on i.billing_period = u.billing_period
cross join exc
cross join dr
