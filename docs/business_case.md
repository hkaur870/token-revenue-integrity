# Business case: revenue integrity for token-priced AI billing

**Bottom line:** at Anthropic's scale, billing accuracy is a top-line lever. Annualized revenue passed $65 billion by the end of July 2026, more than seven times its pace at the end of 2025 ([Bloomberg Tax](https://news.bgov.com/financial-accounting/anthropic-revenue-run-rate-surpasses-65-billion-ahead-of-ipo)). At that run rate, **every basis point (0.01%) of billing error is about $6.5 million a year**, lost in revenue or overcharged to customers. This project shows how I would build the data foundation that keeps that number near zero.

## 1. Why this is hard, based on public information

**A wide pricing surface.** From the [public pricing page](https://platform.claude.com/docs/en/about-claude/pricing), one API request can be shaped by:

| Pricing rule | Where an error would hide |
|---|---|
| Five token categories per model: input, output, 5-minute cache write (1.25x), 1-hour cache write (2x), cache hit | A cache category priced from the wrong column |
| Model-specific cache-hit rates: 0.1x on most models, 0.05x on Opus 5.5 and Sonnet 5.5, 0.025x on Fable 5.1 and Mythos 5.1 | A generic 0.1x rule left in place when a new model ships |
| Haiku 5.5 long-prompt pricing above 100,000 prompt tokens, **where cache reads and writes count toward the threshold** | Measuring prompt length from fresh input only, so long, mostly-cached prompts get the cheap rate |
| Batch API 50% off, combinable with caching | Applying the discount to input and output but not to cache tokens |
| `inference_geo: "us"` at 1.1x, only on Claude 4.6+ models | Multiplier dropped, or applied to ineligible models |
| Fast mode premium pricing | Fast requests rated at standard prices |
| Web search ($10 per 1,000; failed searches free) and code execution (5-minute minimum, 1,550 free hours per org, then $0.05/hour) | Failed searches billed; free hours never subtracted |

Every rule has to be applied the same way in rating, invoicing, partner settlements, and financial reporting, including each time a new model launches.

**Several ways to pay.** API customers [prepay credits that expire after one year](https://support.claude.com/en/articles/8977456-how-do-i-pay-for-my-claude-api-usage), with optional auto-reload. Max and Team subscribers get [monthly API credits that are spent first and expire each month](https://platform.claude.com/docs/en/about-claude/api-credits-for-subscribers). Larger customers are invoiced monthly in arrears. On Claude Platform on AWS and Microsoft Foundry, usage is billed in arrears in Claude Consumption Units ($0.01 each). Each model has its own revenue, deferred revenue, and reconciliation logic.

**Flat-rate plans next to metered usage.** In July 2025, Anthropic added weekly limits for subscribers, citing users "running Claude 24/7 in the background" and account sharing, and said the change affected fewer than 5% of users ([Stark Insider](https://www.starkinsider.com/2025/07/anthropic-adds-weekly-limits-to-claude-cites-abuses.html)). How concentrated heavy usage is, and what a limit would change, is a recurring question that billing data should answer quickly.

## 2. What I built

A dbt + DuckDB pipeline that rates about **1 million synthetic API requests** at public list prices and reconciles every channel:

| Check | What it answers |
|---|---|
| `recon_usage_to_invoice` | Did invoiced customers pay exactly what their usage was worth? If not, **which pricing rule went wrong?** |
| `recon_partner_settlements` | Do partner CCU settlements match our own metering? |
| `recon_prepaid_usage_to_ledger`, `recon_credit_lots` | Did credits draw down correctly, expire on time, and stop usage at zero? |
| `deferred_revenue_rollforward` | Opening, purchases, revenue recognized, breakage, and closing deferred revenue |
| `recon_invoice_to_payment`, `recon_billing_to_gl` | Was it collected, and does the general ledger agree? |
| `mart_pricing_levers` | How much revenue each discount and premium moves |
| `mart_subscription_economics`, `mart_usage_cap_scenarios` | Plan price vs. API-list-price value of usage, and what a usage cap would change |

**How the diagnosis works:** each request is priced correctly *and* under each known mistake. When an invoice line doesn't match, the pipeline checks which mistake reproduces the invoiced amount to the cent, and labels it. Anything no scenario explains is flagged `unexplained` for a person to investigate.

## 3. What it found in the synthetic month

Fourteen problems were planted; the monitor found all of them and named the right cause for each. See the [full report](../reports/revenue_integrity_report.md).

| Finding | Direction | Why it matters |
|---|---|---|
| Haiku 5.5 long prompts billed at the short-prompt rate | Leakage | Largest billing error; the invoice looks normal, so only rule-level reconciliation catches it |
| Requests served after prepaid credits hit zero | Leakage | Credit enforcement gap; usage delivered with no payment |
| Credits spent after their one-year expiry | Leakage | Breakage understated; deferred revenue wrong |
| US-only inference billed without the 1.1x multiplier | Leakage | A premium feature given away |
| Partner settlement closes the month in Pacific time | Leakage (timing) | Revenue shifts between months across channels |
| Batch discount skipped on cache tokens; cache hits at 0.1x instead of 0.05x; duplicates billed; free code-execution hours missed; failed searches billed | Overcharge | Each one costs customer trust and credits issued later |

The planted error rates are deliberately high so they're easy to see. The point is the method, not the size: **a rule-level check finds errors that totals-level checks miss.**

## 4. Recommendations

1. **One canonical rated-usage dataset.** Invoicing, partner reconciliation, credit draw-down, and finance reporting should all read from the same request-level rating, so a pricing rule exists in exactly one place.
2. **Reconcile daily, not at month end.** Run every check daily with dollar thresholds and named owners, so errors are fixed inside the month, before invoices go out.
3. **A regression test for every pricing rule.** When a model launches or a price changes, the price book change ships with tests that rate known requests to known amounts.
4. **Agree on partner cutoffs in writing.** UTC month boundaries and CCU rounding rules in every partner settlement, checked automatically.
5. **Credit controls as data checks.** Block requests at zero balance, enforce lot expiry, and recognize breakage monthly from the ledger.
6. **Track usage concentration by plan.** A standing view of usage relative to price lets pricing and limits decisions start from data.

## 5. My first 90 days on Billing & Payments data

- **Days 1-30:** learn the billing, usage, and payments data models; map every pricing rule to where it's implemented; ship one reconciliation that runs daily.
- **Days 31-60:** build canonical billing and usage datasets in dbt with integrity tests and SLAs; stand up a dashboard Finance can use without writing SQL.
- **Days 61-90:** cover every channel (prepaid, invoiced, cloud partners); add rule-level regression tests to the model-launch process; agree on success metrics (leakage and overcharge in basis points) with Billing Engineering and Finance.

## 6. Why I built this

I run usage-based monthly billing and annual subscription renewals at Comcast's MachineQ. I built an annual renewal process that consolidates more than $1 million into single annual invoices, reduced outstanding receivables 90% (from $2M to under $200K), and automated month-end reporting from over four hours to under ten minutes. I built a Salesforce pricing and billing system in-house in about a month, avoiding an estimated $3 million consulting engagement. This project applies that experience to the billing problems a token-priced AI business faces.

_All customer and usage data in this project is synthetic. Bugs and partner behavior are hypothetical scenarios, not claims about Anthropic's systems. This is an independent project, not affiliated with Anthropic._
