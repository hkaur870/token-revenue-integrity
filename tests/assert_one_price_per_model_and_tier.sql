select model, pricing_tier
from {{ ref('stg_price_book') }}
group by model, pricing_tier
having count(*) > 1
