"""Ask Claude to turn the monitor's exceptions into a summary Finance can act on.

Run after `dbt build` with an Anthropic API key set:
    export ANTHROPIC_API_KEY=...
    python scripts/explain_exceptions.py
Writes reports/ai_summary.md. Without a key, it explains how to add one and exits.
"""
import os
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "reports" / "ai_summary.md"
MODEL = os.environ.get("CLAUDE_MODEL", "claude-sonnet-5-5")

PROMPT = """You are a billing operations analyst writing for a Finance and Billing Engineering audience.
Below is this month's output from an automated usage-to-cash reconciliation monitor for a
token-priced AI API business (priced with public list prices; all usage and customers are synthetic).

Write a concise summary (under 300 words) with:
1. A two-sentence headline: revenue leakage vs. customer overcharges, in dollars and basis points of usage.
2. The top issues ranked by dollars, each with its likely cause and a specific next step and owner
   (Billing Engineering, Finance, Collections, Partnerships, or Data Engineering).
3. One process fix that would prevent the largest category from recurring.
Use only the numbers provided. Do not invent customers or amounts.

BILLING SUMMARY
{summary}

EXCEPTIONS (severity | area | org | reference | dollars at risk | direction | likely cause | detail)
{exceptions}
"""


def gather(conn):
    cols = ["billing_period", "requests", "rated_usage_usd", "invoiced_usd", "collected_usd", "open_receivables_usd",
            "deferred_revenue_closing_usd", "breakage_usd", "revenue_leakage_usd", "customer_overcharges_usd",
            "leakage_bps_of_usage", "overcharge_bps_of_usage", "exception_count", "total_at_risk_usd"]
    row = conn.execute(f"select {', '.join(cols)} from billing_summary").fetchone()
    summary = "\n".join(f"{c}: {v}" for c, v in zip(cols, row))
    rows = conn.execute("""
        select severity, domain, org_id, reference_id, amount_at_risk, direction, likely_cause, detail
        from billing_exceptions where domain <> 'metering' order by amount_at_risk desc limit 40
    """).fetchall()
    exceptions = "\n".join(" | ".join(str(v) for v in r) for r in rows)
    return summary, exceptions


def summarize(conn, api_key=None):
    import anthropic
    client = anthropic.Anthropic(api_key=api_key or os.environ["ANTHROPIC_API_KEY"])
    summary, exceptions = gather(conn)
    msg = client.messages.create(
        model=MODEL,
        max_tokens=1000,
        messages=[{"role": "user", "content": PROMPT.format(summary=summary, exceptions=exceptions)}],
    )
    return "".join(block.text for block in msg.content if block.type == "text")


if __name__ == "__main__":
    if not os.environ.get("ANTHROPIC_API_KEY"):
        raise SystemExit("Set ANTHROPIC_API_KEY to generate the AI summary (see README).")
    import duckdb
    conn = duckdb.connect(str(ROOT / "token_revenue.duckdb"), read_only=True)
    text = summarize(conn)
    OUT.parent.mkdir(exist_ok=True)
    OUT.write_text("# AI Summary for Finance\n\n_Written by Claude from the monitor's output (synthetic data)._\n\n" + text + "\n")
    print(f"Wrote {OUT}")
