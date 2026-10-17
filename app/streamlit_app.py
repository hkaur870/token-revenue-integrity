"""Revenue integrity dashboard for token-priced AI billing.

Run locally:   streamlit run app/streamlit_app.py
On first start it generates synthetic data and runs `dbt build`, then reads the results.
"""
import os
import subprocess
import sys
from pathlib import Path

import duckdb
import streamlit as st

ROOT = Path(__file__).resolve().parent.parent
DB = ROOT / "token_revenue.duckdb"
sys.path.insert(0, str(ROOT / "scripts"))
from build_report import CAUSES  # noqa: E402

st.set_page_config(page_title="Token Revenue Integrity", layout="wide")


@st.cache_resource(show_spinner="Generating synthetic usage and running the dbt pipeline (about a minute)...")
def build_pipeline():
    if not DB.exists():
        subprocess.run([sys.executable, str(ROOT / "scripts" / "generate_data.py"), "--requests", "250000"],
                       check=True, cwd=ROOT)
        from dbt.cli.main import dbtRunner
        os.chdir(ROOT)
        result = dbtRunner().invoke(["build", "--profiles-dir", str(ROOT), "--project-dir", str(ROOT)])
        if not result.success:
            raise RuntimeError("dbt build failed; run it locally to see the error.")
    return True


def query(sql):
    with duckdb.connect(str(DB), read_only=True) as conn:
        return conn.execute(sql).df()


def label(df, col="likely_cause"):
    df[col] = df[col].map(lambda c: CAUSES.get(c, c))
    return df


def api_key():
    try:
        return st.secrets["ANTHROPIC_API_KEY"]
    except Exception:
        return os.environ.get("ANTHROPIC_API_KEY")


build_pipeline()

st.title("Token Revenue Integrity Monitor")
st.caption("Follows every dollar of token-priced AI usage from metering to cash across three channels "
           "(invoiced, prepaid credits, cloud marketplaces) and traces each leak to its cause. "
           "Prices follow Anthropic's public pricing; all customers and usage are synthetic.")

s = query("select * from billing_summary").iloc[0]
c1, c2, c3, c4 = st.columns(4)
c1.metric("Rated usage", f"${s.rated_usage_usd:,.0f}", help=f"{int(s.requests):,} requests, {s.total_tokens / 1e9:,.1f}B tokens")
c2.metric("Revenue leakage", f"${s.revenue_leakage_usd:,.0f}", f"{s.leakage_bps_of_usage} bps of usage", delta_color="inverse")
c3.metric("Customer overcharges", f"${s.customer_overcharges_usd:,.0f}", f"{s.overcharge_bps_of_usage} bps of usage", delta_color="inverse")
c4.metric("Exceptions found", int(s.exception_count))

tabs = st.tabs(["Billing accuracy", "Partner channels", "Prepaid credits", "Pricing levers", "Subscriptions", "Summary by Claude"])

with tabs[0]:
    st.subheader("Dollars at risk by cause")
    by_cause = label(query("""
        select likely_cause, direction, round(sum(amount_at_risk), 2) as dollars
        from billing_exceptions where domain <> 'metering'
        group by likely_cause, direction order by dollars desc
    """))
    st.bar_chart(by_cause, x="likely_cause", y="dollars", color="direction", horizontal=True)
    st.subheader("Invoice mismatches, each traced to a cause")
    st.dataframe(label(query("""
        select org_id, line_item, expected_amount, billed_amount, variance, likely_cause
        from recon_usage_to_invoice where status <> 'matched' order by abs(variance) desc
    """)), use_container_width=True, hide_index=True)

with tabs[1]:
    st.subheader("Metered usage vs. partner CCU settlements")
    st.caption("Claude Platform on AWS and Microsoft Foundry bill in arrears in Claude Consumption Units ($0.01 each).")
    st.dataframe(label(query("""
        select org_id, channel, expected_ccus, settled_ccus, variance_usd, status, likely_cause
        from recon_partner_settlements order by variance_usd
    """)), use_container_width=True, hide_index=True)

with tabs[2]:
    st.subheader("Deferred revenue roll-forward")
    st.dataframe(query("select * from deferred_revenue_rollforward order by lot_type desc"),
                 use_container_width=True, hide_index=True)
    st.caption("Purchased credits expire one year after purchase (breakage). Included subscriber credits are spent "
               "first and expire monthly; they are shown as a memo line.")
    st.subheader("Credit exceptions")
    st.dataframe(label(query("""
        select org_id, exception_type, reference_id, amount_at_risk, likely_cause, detail
        from billing_exceptions where domain = 'prepaid_credits' order by amount_at_risk desc
    """)), use_container_width=True, hide_index=True)

with tabs[3]:
    st.subheader("Revenue effect of each pricing lever vs. list price")
    levers = query("select lever, revenue_effect_usd, requests_affected from mart_pricing_levers")
    st.bar_chart(levers, x="lever", y="revenue_effect_usd", horizontal=True)
    st.dataframe(levers, use_container_width=True, hide_index=True)
    st.subheader("Daily expected revenue by model")
    daily = query("""select usage_date, model, sum(expected_revenue_usd) as revenue
                     from mart_daily_usage group by usage_date, model order by usage_date""")
    st.line_chart(daily.pivot(index="usage_date", columns="model", values="revenue"))

with tabs[4]:
    st.subheader("Plan price vs. API-list-price value of usage (illustrative)")
    st.dataframe(query("select * from mart_subscription_economics order by monthly_price_usd"),
                 use_container_width=True, hide_index=True)
    st.subheader("What-if: cap usage at N x plan price")
    st.dataframe(query("select * from mart_usage_cap_scenarios order by cap_multiple"),
                 use_container_width=True, hide_index=True)
    st.caption("Subscription usage is synthetic. The point is the method: measuring how concentrated heavy usage is, "
               "and how few subscribers a limit touches.")

with tabs[5]:
    key = api_key()
    if key:
        if st.button("Write a summary for Finance"):
            from explain_exceptions import summarize
            with st.spinner("Asking Claude..."):
                with duckdb.connect(str(DB), read_only=True) as conn:
                    st.markdown(summarize(conn, api_key=key))
    else:
        st.info("Add an ANTHROPIC_API_KEY secret to have Claude summarize these exceptions for Finance.")
