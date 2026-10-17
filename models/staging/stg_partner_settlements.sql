-- Partner-reported consumption for Claude Platform on AWS and Microsoft Foundry, in CCUs.
select
    settlement_id, org_id, channel,
    cast(billing_period as varchar)               as billing_period,
    cast(ccus_billed as bigint)                   as ccus_billed,
    cast(settlement_amount_usd as decimal(18, 2)) as settlement_amount_usd
from {{ ref('raw_partner_settlements') }}
