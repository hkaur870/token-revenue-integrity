-- Every successful request must find a price; unpriced usage can never be billed.
select d.request_id
from {{ ref('int_requests_deduped') }} d
left join {{ ref('int_rated_requests') }} r on r.request_id = d.request_id
where d.status = 'succeeded' and r.request_id is null
