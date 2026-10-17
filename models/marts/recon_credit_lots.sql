-- Every credit lot must roll forward cleanly: opening + added - consumed - expired = closing,
-- with no consumption after the lot expired and no balance left on an expired lot.
with movements as (
    select lot_id,
        sum(case when entry_type in ('grant', 'purchase') then amount else 0 end)  as added,
        -sum(case when entry_type = 'consumption' then amount else 0 end)          as consumed,
        -sum(case when entry_type = 'expiration' then amount else 0 end)           as expired,
        -sum(case when entry_type = 'consumption' and entry_date > l_expires_on then amount else 0 end) as consumed_after_expiry
    from (
        select g.*, l.expires_on as l_expires_on
        from {{ ref('stg_credit_ledger') }} g
        join {{ ref('stg_credit_lots') }} l on l.lot_id = g.lot_id
    ) x
    group by lot_id
)
select
    l.lot_id, l.org_id, l.lot_type, l.acquired_on, l.expires_on,
    round(l.opening_balance, 2)                                        as opening_balance,
    round(coalesce(m.added, 0), 2)                                     as added,
    round(coalesce(m.consumed, 0), 2)                                  as consumed,
    round(coalesce(m.expired, 0), 2)                                   as expired,
    round(l.opening_balance + coalesce(m.added, 0) - coalesce(m.consumed, 0) - coalesce(m.expired, 0), 2) as closing_balance,
    round(coalesce(m.consumed_after_expiry, 0), 2)                     as consumed_after_expiry,
    case
        when coalesce(m.consumed_after_expiry, 0) > {{ var('tolerance') }} then 'consumed_after_expiry'
        when l.expires_on <= '{{ var("billing_period") }}-31'
         and l.opening_balance + coalesce(m.added, 0) - coalesce(m.consumed, 0) - coalesce(m.expired, 0) > {{ var('tolerance') }}
            then 'expired_balance_not_released'
        when l.opening_balance + coalesce(m.added, 0) - coalesce(m.consumed, 0) - coalesce(m.expired, 0) < -{{ var('tolerance') }}
            then 'negative_balance'
        else 'ok'
    end as status
from {{ ref('stg_credit_lots') }} l
left join movements m on m.lot_id = l.lot_id
