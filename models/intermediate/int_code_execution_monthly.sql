-- Code execution is billed per org per month: 5-minute minimum per execution,
-- 1,550 free container-hours, then $0.05 per hour.
select
    org_id,
    usage_month as billing_period,
    count(*)                                         as executions,
    sum(code_billable_seconds) / 3600.0              as billable_hours,
    case when sum(code_billable_seconds) / 3600.0 > {{ var('code_free_hours') }}
         then (sum(code_billable_seconds) / 3600.0 - {{ var('code_free_hours') }}) * {{ var('code_usd_per_hour') }}
         else 0 end                                  as expected_charge,
    sum(code_billable_seconds) / 3600.0 * {{ var('code_usd_per_hour') }} as charge_if_free_hours_missed
from {{ ref('int_rated_requests') }}
where code_exec_seconds > 0
group by org_id, usage_month
