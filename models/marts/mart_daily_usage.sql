select usage_date, model, segment,
       count(*)                            as requests,
       sum(prompt_tokens + output_tokens)  as total_tokens,
       round(sum(token_amount + search_amount), 2) as expected_revenue_usd
from {{ ref('int_rated_requests') }}
group by usage_date, model, segment
