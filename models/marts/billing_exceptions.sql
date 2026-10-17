-- Every issue the monitor found: domain, severity, dollars at risk, and the most likely cause.
-- direction: 'leakage' = revenue lost or not yet collected; 'overcharge' = customer billed too much.
select 'invoicing' as domain, 'usage_' || status as exception_type, 'high' as severity,
       org_id, line_item as reference_id, abs(variance) as amount_at_risk,
       case when variance < 0 then 'leakage' else 'overcharge' end as direction,
       likely_cause,
       'Expected ' || cast(expected_amount as varchar) || ', invoiced ' || cast(billed_amount as varchar) as detail
from {{ ref('recon_usage_to_invoice') }}
where status <> 'matched'

union all
select 'partner_channel', 'settlement_mismatch', 'high', org_id, channel, abs(variance_usd),
       case when variance_usd < 0 then 'leakage' else 'overcharge' end,
       likely_cause,
       'Expected ' || cast(expected_ccus as varchar) || ' CCUs, partner settled ' || cast(settled_ccus as varchar)
from {{ ref('recon_partner_settlements') }}
where status <> 'matched'

union all
select 'prepaid_credits', 'usage_served_without_credit', 'high', org_id, 'unfunded', unfunded_usage_usd,
       'leakage', 'auto_reload_off_and_requests_not_blocked',
       'Usage worth ' || cast(unfunded_usage_usd as varchar) || ' served after credits ran out'
from {{ ref('recon_prepaid_usage_to_ledger') }}
where unfunded_usage_usd > {{ var('tolerance') }}

union all
select 'prepaid_credits', 'credit_lot_' || status, 'medium', org_id, lot_id,
       case when status = 'consumed_after_expiry' then consumed_after_expiry else abs(closing_balance) end,
       'leakage',
       case when status = 'consumed_after_expiry' then 'expired_credits_still_spendable'
            when status = 'expired_balance_not_released' then 'breakage_not_recognized'
            else 'lot_overdrawn' end,
       'Lot expired ' || expires_on || '; consumed after expiry ' || cast(consumed_after_expiry as varchar)
from {{ ref('recon_credit_lots') }}
where status <> 'ok'

union all
select 'collections', 'invoice_' || status, case when is_past_due then 'high' else 'medium' end,
       org_id, invoice_id, abs(open_balance), 'leakage',
       case when is_past_due then 'past_due_collections' else 'awaiting_payment' end,
       'Invoiced ' || cast(invoice_amount as varchar) || ', collected ' || cast(amount_paid as varchar)
from {{ ref('recon_invoice_to_payment') }}
where status <> 'paid'

union all
select 'general_ledger', 'gl_mismatch', 'high', org_id, billing_period, abs(variance),
       case when variance > 0 then 'overstatement' else 'understatement' end,
       'journal_entry_differs_from_invoice',
       'GL booked ' || cast(booked_amount as varchar) || ' vs invoiced ' || cast(invoiced_amount as varchar)
from {{ ref('recon_billing_to_gl') }}
where status = 'mismatch'

union all
select 'metering', 'duplicate_requests', 'low', d.org_id,
       cast(count(*) as varchar) || ' requests',
       round(sum((r.token_amount + r.search_amount) * (d.copies - 1)), 2),
       'risk', 'metering_retries',
       'Metering sent ' || cast(count(*) as varchar) || ' requests more than once (de-duplicated by the monitor)'
from {{ ref('int_duplicate_requests') }} d
join {{ ref('int_rated_requests') }} r on r.request_id = d.request_id
group by d.org_id
