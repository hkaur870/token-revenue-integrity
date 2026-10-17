select
    org_id,
    org_name,
    segment,                 -- enterprise_invoiced | self_serve_prepaid | cloud_marketplace
    channel,                 -- first_party | aws_platform | microsoft_foundry
    linked_plan,             -- Claude plan linked to the Console org (drives included monthly API credits)
    cast(team_standard_seats as integer) as team_standard_seats,
    cast(team_premium_seats as integer)  as team_premium_seats
from {{ ref('raw_orgs') }}
