-- Purchased credits are cash received for services not yet delivered (deferred revenue).
-- Revenue is recognized as credits are consumed; expired credits are recognized as breakage.
-- Included subscriber credits are shown separately as a memo: they are part of a subscription,
-- not a separate cash purchase.
select
    l.lot_type,
    round(sum(l.opening_balance), 2)                           as opening_balance,
    round(sum(l.added), 2)                                     as purchases_or_grants,
    round(sum(l.consumed), 2)                                  as recognized_from_usage,
    round(sum(l.expired), 2)                                   as expired_breakage,
    round(sum(l.closing_balance), 2)                           as closing_balance,
    count(*)                                                   as lots
from {{ ref('recon_credit_lots') }} l
group by l.lot_type
