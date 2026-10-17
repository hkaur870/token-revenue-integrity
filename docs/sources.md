# Sources

Every price and billing rule in this project comes from public pages, read in October 2026. Customers, usage, invoices, payments, and subscription usage are synthetic.

| What | Used for | Source |
|---|---|---|
| Model prices per million tokens (input, output, 5-minute and 1-hour cache writes, cache hits); batch discount; Haiku 5.5 long-prompt pricing; fast mode; `inference_geo` 1.1x; web search and code execution pricing; CCUs on Claude Platform on AWS and Microsoft Foundry | `seeds/raw_price_book.csv`, `int_rated_requests`, `int_code_execution_monthly`, `recon_partner_settlements` | [Claude API pricing](https://platform.claude.com/docs/en/about-claude/pricing) |
| Prepaid credits, auto-reload, one-year credit expiry, monthly invoicing in arrears | Credit lots, ledger, deferred revenue roll-forward | [How do I pay for my Claude API usage?](https://support.claude.com/en/articles/8977456-how-do-i-pay-for-my-claude-api-usage) |
| Monthly API credits for Max and Team plans: amounts, $500 Team cap, spent first, expire monthly | Included credit lots | [API credits for Max and Team plans](https://platform.claude.com/docs/en/about-claude/api-credits-for-subscribers) |
| Claude plan prices (Pro, Max, Team) | `mart_subscription_economics` | [Plans & pricing](https://claude.com/pricing), [What is the Max plan?](https://support.claude.com/en/articles/11049741-what-is-the-max-plan) |
| Weekly usage limits for subscribers (announced July 2025, citing 24/7 background use and account sharing; under 5% of users affected) | Business context for subscription economics | [Stark Insider, July 28, 2025](https://www.starkinsider.com/2025/07/anthropic-adds-weekly-limits-to-claude-cites-abuses.html) |
| Annualized revenue above $65 billion by end of July 2026, up more than sevenfold from the end of 2025 | Business case sizing | [Bloomberg Tax, Aug. 18, 2026](https://news.bgov.com/financial-accounting/anthropic-revenue-run-rate-surpasses-65-billion-ahead-of-ipo) |

## Assumptions where public docs are silent

- **Batch + caching:** the pricing page says the two discounts "can be combined." The model applies the 50% batch discount to every token category, including cache writes and hits.
- **Fast-mode cache prices:** not published separately, so synthetic fast-mode requests carry no cache tokens.
- **Code execution:** modeled with the 5-minute minimum per execution and 1,550 free hours per org per month; the free-with-web-search exception is not modeled.
- **Credit draw-down order among purchased lots:** included credits are spent first (documented); purchased lots are then drawn earliest-expiry first (assumed).
- **The Pacific-time partner cutoff, the planted billing bugs, and all subscription usage distributions are hypothetical scenarios** built to show how the monitor works. They are not claims about Anthropic's systems or partners.
