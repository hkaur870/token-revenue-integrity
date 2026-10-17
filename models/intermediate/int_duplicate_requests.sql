select request_id, min(org_id) as org_id, count(*) as copies
from {{ ref('stg_api_requests') }}
group by request_id
having count(*) > 1
