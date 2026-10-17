"""Generate one month (September 2026) of synthetic billing data for a token-priced AI API.

Prices and billing rules follow Anthropic's PUBLIC documentation (see docs/sources.md):
  * per-model prices for input, output, 5-minute and 1-hour cache writes, and cache hits
  * Claude Haiku 5.5 long-prompt pricing for prompts over 100,000 tokens (cache tokens count)
  * Batch API: 50% off; stacks with prompt caching
  * Fast mode (Opus 5.5) at premium rates; not available with batch
  * inference_geo="us": 1.1x on all token categories, Claude 4.6+ models only
  * Web search: $10 per 1,000 searches; failed searches are not billed
  * Code execution: 5-minute minimum per execution, 1,550 free hours per org per month,
    then $0.05 per container-hour
  * Prepaid credits expire one year after purchase; subscriber monthly API credits are
    spent first and expire at month end; auto-reload tops up purchased credits
  * Claude Platform on AWS and Microsoft Foundry bill in arrears in Claude Consumption
    Units (CCUs) at $0.01 per CCU

Customers, usage, invoices, payments, and subscriptions are entirely made up.
A simulated billing system then bills the usage with realistic bugs planted on purpose,
so the reconciliation pipeline has something real to find.

Run:  python scripts/generate_data.py                  (about 1,000,000 API requests)
      python scripts/generate_data.py --requests 60000 (quick local run)
"""
import argparse
import csv
import math
import random
from collections import defaultdict
from datetime import datetime, timedelta
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SEEDS, RAW = ROOT / "seeds", ROOT / "data" / "raw"

PERIOD = "2026-09"
START = datetime(2026, 9, 1)
SECONDS_IN_MONTH = 30 * 24 * 3600
BILLING_CUTOFF = "2026-10-01 06:00:00"    # usage ingested after this misses the month-end run
PACIFIC_OFFSET_HOURS = 7                  # PDT, used by one partner's settlement cutoff

# model, pricing_tier, $/MTok input, output, 5m cache write, 1h cache write, cache hit, geo eligible
PRICE_BOOK = [
    ("claude-opus-5-5",   "standard",     4.00, 20.00, 5.00,  8.00,  0.20, 1),
    ("claude-opus-5-5",   "fast",         8.00, 40.00, 10.00, 16.00, 0.40, 1),
    ("claude-sonnet-5-5", "standard",     2.00, 10.00, 2.50,  4.00,  0.10, 1),
    ("claude-haiku-5-5",  "standard",     0.10,  0.50, 0.125, 0.20,  0.01, 1),
    ("claude-haiku-5-5",  "long_context", 0.50,  2.50, 0.625, 1.00,  0.05, 1),
    ("claude-opus-4-8",   "standard",     5.00, 25.00, 6.25, 10.00,  0.50, 1),
    ("claude-sonnet-4-5", "standard",     3.00, 15.00, 3.75,  6.00,  0.30, 0),
]
PRICE = {(m, t): (i, o, w5, w1, h, g) for m, t, i, o, w5, w1, h, g in PRICE_BOOK}
MODELS = ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5", "claude-opus-4-8", "claude-sonnet-4-5"]
HAIKU_LONG_THRESHOLD = 100_000
BATCH, GEO_US = 0.5, 1.1
SEARCH_PRICE = 0.01                       # $10 per 1,000
CODE_MIN_SECONDS, CODE_FREE_HOURS, CODE_PRICE_PER_HOUR = 300, 1550, 0.05
CCU_USD = 0.01

# ---- planted billing bugs (one per invoiced customer, so each is diagnosable) ----------
BUG_HAIKU_TIER = "E05"   # prompt length measured without cache tokens -> long prompts billed at the short rate
BUG_GEO = "E08"          # US-only inference billed without the 1.1x multiplier
BUG_CACHE_HIT = "E11"    # cache hits on Opus/Sonnet 5.5 billed at the generic 0.1x instead of 0.05x
BUG_BATCH_CACHE = "E14"  # batch discount applied to input/output but not to cache tokens
BUG_FAILED_SEARCH = "E17"  # failed web searches billed
BUG_FREE_HOURS = "E20"   # 1,550 free code-execution hours not applied
LATE_ORG = "E23"         # a burst of usage ingested after the billing cutoff
DUP_ORG = "E26"          # metering retries double-counted on the invoice
UNPAID, PARTIAL, GL_ERROR = "E03", "E12", "E19"
EXPIRED_LOT_ORG, UNFUNDED_ORG = "P042", "P077"


def segment_orgs(rng):
    words1 = ["North", "Blue", "Cedar", "Summit", "Harbor", "Atlas", "Lumen", "Copper", "Vista", "Iron",
              "Maple", "Orbit", "Signal", "Pioneer", "Granite", "Beacon", "Quarry", "Willow", "Delta", "Falcon"]
    words2 = ["Health", "Labs", "Legal", "Logistics", "Analytics", "Robotics", "Media", "Capital", "Systems",
              "Retail", "Bio", "Insurance", "Learning", "Energy", "Software", "Security", "Foods", "Travel"]
    names = set()

    def name():
        while True:
            n = f"{rng.choice(words1)} {rng.choice(words2)}"
            if n not in names:
                names.add(n)
                return n

    orgs = []
    for i in range(1, 31):
        orgs.append((f"E{i:02d}", name(), "enterprise_invoiced", "first_party", None, 0, 0))
    plans = ["max_5x"] * 30 + ["max_20x"] * 20 + ["team"] * 20 + [None] * 30
    rng.shuffle(plans)
    for i in range(1, 101):
        plan = plans[i - 1]
        std = rng.randint(2, 10) if plan == "team" else 0
        prem = rng.randint(0, 3) if plan == "team" else 0
        orgs.append((f"P{i:03d}", name(), "self_serve_prepaid", "first_party", plan, std, prem))
    for i in range(1, 21):
        ch = "aws_platform" if i <= 10 else "microsoft_foundry"
        orgs.append((f"C{i:02d}", name(), "cloud_marketplace", ch, None, 0, 0))
    return orgs


def included_credit(plan, std, prem):
    if plan == "max_5x":
        return 100.0
    if plan == "max_20x":
        return 200.0
    if plan == "team":
        return min(500.0, 20.0 * std + 100.0 * prem)
    return 0.0


def make_profile(rng, oid, segment, channel):
    if segment == "enterprise_invoiced":
        weight = rng.lognormvariate(3.0, 0.8)
    elif segment == "cloud_marketplace":
        weight = rng.lognormvariate(2.4, 0.7)
    else:
        weight = rng.lognormvariate(0.0, 0.9)
    mix = [rng.random() for _ in MODELS]
    if oid == BUG_HAIKU_TIER:
        mix[2] *= 6
    if oid in (BUG_CACHE_HIT, BUG_BATCH_CACHE):
        mix[0] *= 3
        mix[1] *= 3
    return {
        "weight": weight,
        "mix": [m / sum(mix) for m in mix],
        "batch_share": 0.45 if oid == BUG_BATCH_CACHE else rng.choice([0.0, 0.1, 0.25]),
        "fast_share": 0.06 if (channel == "first_party" and rng.random() < 0.3) else 0.0,
        "geo_us_share": 0.6 if oid == BUG_GEO else (0.3 if rng.random() < 0.2 else 0.0),
        "cache_user": oid in (BUG_CACHE_HIT, BUG_BATCH_CACHE, BUG_HAIKU_TIER) or rng.random() < 0.7,
        "long_prompt_share": 0.35 if oid == BUG_HAIKU_TIER else 0.04,
        "search_share": 0.25 if oid == BUG_FAILED_SEARCH else 0.04,
        "code_share": 0.5 if oid == BUG_FREE_HOURS else 0.02,
        "code_mean_seconds": 3000 if oid == BUG_FREE_HOURS else 600,
    }


def make_request(rng, rid, oid, channel, prof):
    ts = START + timedelta(seconds=rng.randrange(SECONDS_IN_MONTH))
    model = rng.choices(MODELS, weights=prof["mix"])[0]
    tier = "standard"
    if model == "claude-opus-5-5" and channel == "first_party" and rng.random() < prof["fast_share"]:
        tier = "fast"
    elif rng.random() < prof["batch_share"]:
        tier = "batch"
    geo = "us" if (PRICE[(model, "standard")][5] and rng.random() < prof["geo_us_share"]) else "global"

    inp = int(rng.lognormvariate(9.2, 1.0))          # median ~10k fresh input tokens
    out = int(inp * rng.uniform(0.05, 0.5))
    w5 = w1 = hit = 0
    if prof["cache_user"] and tier != "fast":
        w5 = int(inp * rng.uniform(0, 0.4)) if rng.random() < 0.5 else 0
        w1 = int(inp * rng.uniform(0, 0.3)) if rng.random() < 0.2 else 0
        hit = int(inp * rng.uniform(1, 15))
    if model == "claude-haiku-5-5" and rng.random() < prof["long_prompt_share"]:
        # long-context request: fresh input stays under 100k, cached context pushes the prompt over it
        inp = rng.randint(20_000, 90_000)
        hit = rng.randint(60_000, 400_000)
        out = rng.randint(500, 8_000)
    searches = failed = 0
    if rng.random() < prof["search_share"]:
        searches = rng.randint(1, 5)
        failed = sum(1 for _ in range(searches) if rng.random() < 0.15)
    code = int(rng.expovariate(1 / prof["code_mean_seconds"])) + 1 if rng.random() < prof["code_share"] else 0
    status = "failed" if rng.random() < 0.012 else "succeeded"
    ingested = ts + timedelta(seconds=rng.randint(5, 900))
    return [rid, oid, ts.strftime("%Y-%m-%d %H:%M:%S"), model, tier, geo, status,
            inp, w5, w1, hit, out, searches, failed, code, ingested.strftime("%Y-%m-%d %H:%M:%S")]


def token_cost(req, haiku_ignore_cache=False, no_geo=False, cache_hit_generic=False, batch_skip_cache=False):
    model, tier, geo = req[3], req[4], req[5]
    inp, w5, w1, hit, out = req[7], req[8], req[9], req[10], req[11]
    price_tier = "fast" if tier == "fast" else "standard"
    prompt = inp if haiku_ignore_cache else inp + w5 + w1 + hit
    if model == "claude-haiku-5-5" and prompt > HAIKU_LONG_THRESHOLD:
        price_tier = "long_context"
    pi, po, pw5, pw1, ph, _ = PRICE[(model, price_tier)]
    if cache_hit_generic:
        ph = 0.1 * pi
    geo_m = 1.0 if (no_geo or geo != "us") else GEO_US
    b = BATCH if tier == "batch" else 1.0
    io = (inp * pi + out * po) * b
    cache = (w5 * pw5 + w1 * pw1 + hit * ph) * (1.0 if batch_skip_cache else b)
    return geo_m * (io + cache) / 1_000_000


def write(path, header, rows):
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(header)
        w.writerows(rows)


def main(n_requests, seed):
    rng = random.Random(seed)
    orgs = segment_orgs(rng)
    org = {o[0]: o for o in orgs}
    profiles = {o[0]: make_profile(rng, o[0], o[2], o[3]) for o in orgs}
    total_w = sum(p["weight"] for p in profiles.values())

    # ---- API requests ---------------------------------------------------------------
    requests, rid = [], 1
    for oid, prof in profiles.items():
        n = max(30, int(n_requests * prof["weight"] / total_w))
        for _ in range(n):
            requests.append(make_request(rng, f"req_{rid:09d}", oid, org[oid][3], prof))
            rid += 1
    # late burst: E23's last 8 hours of September are ingested after the billing cutoff
    for r in requests:
        if r[1] == LATE_ORG and r[2] >= "2026-09-30 16:00:00":
            r[15] = "2026-10-02 09:30:00"
    # metering retries: duplicate copies (most de-duplicated by billing, E26's are not)
    dup_pool = [r for r in requests if r[1] == DUP_ORG and r[6] == "succeeded"]
    dups = [list(r) for r in rng.sample(dup_pool, k=min(1500, len(dup_pool)))]
    others = [r for r in requests if r[1] != DUP_ORG]
    dups += [list(r) for r in rng.sample(others, k=min(300, len(others)))]
    all_requests = requests + dups
    rng.shuffle(all_requests)
    write(RAW / "api_requests.csv",
          ["request_id", "org_id", "request_ts", "model", "service_tier", "inference_geo", "status",
           "input_tokens", "cache_write_5m_tokens", "cache_write_1h_tokens", "cache_read_tokens",
           "output_tokens", "web_search_requests", "web_search_failed", "code_exec_seconds", "ingested_at"],
          all_requests)

    # ---- the billing system: rate and bill with planted bugs ---------------------------
    billed = defaultdict(float)            # (org, line_item) -> amount
    code_seconds = defaultdict(int)
    daily_usage = defaultdict(float)       # (org, date) -> correctly rated amount (prepaid ledger)
    partner_amount = defaultdict(float)    # org -> amount as the partner counts it
    seen = set()
    for r in all_requests:
        oid = r[1]
        if r[6] != "succeeded":
            continue
        if r[0] in seen and oid != DUP_ORG:
            continue
        first_copy = r[0] not in seen
        seen.add(r[0])
        seg, ch = org[oid][2], org[oid][3]
        correct = token_cost(r) + (r[12] - r[13]) * SEARCH_PRICE
        if seg == "self_serve_prepaid" and first_copy:
            daily_usage[(oid, r[2][:10])] += correct
            continue
        if seg == "cloud_marketplace" and first_copy:
            if ch == "microsoft_foundry" and r[2][:10] == "2026-09-01" and int(r[2][11:13]) < PACIFIC_OFFSET_HOURS:
                continue                    # partner books these hours in August (Pacific-time cutoff)
            partner_amount[oid] += correct
            continue
        if r[15] > BILLING_CUTOFF:
            continue                        # missed the billing run
        billed[(oid, r[3])] += token_cost(
            r,
            haiku_ignore_cache=oid == BUG_HAIKU_TIER,
            no_geo=oid == BUG_GEO,
            cache_hit_generic=oid == BUG_CACHE_HIT,
            batch_skip_cache=oid == BUG_BATCH_CACHE,
        )
        searches = r[12] if oid == BUG_FAILED_SEARCH else r[12] - r[13]
        if searches:
            billed[(oid, "web_search")] += searches * SEARCH_PRICE
        if r[14]:
            code_seconds[oid] += max(CODE_MIN_SECONDS, r[14])

    # ---- invoices, payments, and the finance ledger (invoiced customers) -----------------
    invoices, lines, payments, gl = [], [], [], []
    for i, (oid, *_rest) in enumerate([o for o in orgs if o[2] == "enterprise_invoiced"], start=1):
        inv = f"in_2026_09_{oid}"
        total = 0.0
        for (o, item), amt in sorted(billed.items()):
            if o == oid and round(amt, 2) > 0:
                lines.append((inv, item, round(amt, 2)))
                total += round(amt, 2)
        hours = code_seconds[oid] / 3600
        free = 0 if oid == BUG_FREE_HOURS else CODE_FREE_HOURS
        code_charge = round(max(0.0, hours - free) * CODE_PRICE_PER_HOUR, 2)
        if code_charge > 0:
            lines.append((inv, "code_execution", code_charge))
            total += code_charge
        total = round(total, 2)
        invoices.append((inv, oid, PERIOD, "2026-10-01", "2026-10-31", total))
        if oid != UNPAID:
            paid = round(total * 0.6, 2) if oid == PARTIAL else total
            payments.append((f"py_{i:05d}", inv, oid, "2026-10-20", paid, "succeeded"))
        gl.append((f"je_{inv}", oid, PERIOD, round(total * 1.04, 2) if oid == GL_ERROR else total))
    payments.append(("py_09001", invoices[5][0], invoices[5][1], "2026-10-18", invoices[5][5], "failed"))

    # ---- partner settlements (CCU channels, billed in arrears) --------------------------
    settlements = []
    for o in orgs:
        if o[2] == "cloud_marketplace":
            ccus = int(round(partner_amount[o[0]] / CCU_USD))
            settlements.append((f"st_2026_09_{o[0]}", o[0], o[3], PERIOD, ccus, round(ccus * CCU_USD, 2)))

    # ---- prepaid credits: lots, auto-reload, and the consumption ledger ------------------
    lots, ledger = [], []
    led_no = 1

    def entry(oid, day, etype, lot, amount):
        nonlocal led_no
        ledger.append((f"cl_{led_no:07d}", oid, day, etype, lot, round(amount, 6)))
        led_no += 1

    for o in orgs:
        if o[2] != "self_serve_prepaid":
            continue
        oid, plan, std, prem = o[0], o[4], o[5], o[6]
        month_spend = sum(v for (x, _), v in daily_usage.items() if x == oid)
        active = []                                   # [lot_id, expires_at, balance, type]
        inc = 0.0 if oid == EXPIRED_LOT_ORG else included_credit(plan, std, prem)
        if inc:
            lid = f"lot_{oid}_inc_2026_09"
            lots.append((lid, oid, "included", "2026-09-01", "2026-09-30", inc, 0.0))
            entry(oid, "2026-09-01", "grant", lid, inc)
            active.append([lid, "2026-09-30", inc, "included"])
        # purchased lots bought earlier; one older lot expires mid-September (breakage)
        # the older lot is partly unused when it expires (breakage); the recent lot covers the month
        # (orgs with auto-reload keep a smaller balance and top up as they go)
        auto_reload = oid not in (UNFUNDED_ORG, EXPIRED_LOT_ORG) and rng.random() < 0.7
        old = round(month_spend * (0.9 if oid == EXPIRED_LOT_ORG else rng.uniform(0.1, 0.5)), 2)
        if oid == UNFUNDED_ORG:
            recent = round(month_spend * 0.15, 2)
        else:
            recent = round(month_spend * (rng.uniform(0.3, 0.8) if auto_reload else rng.uniform(1.15, 1.8)), 2)
        exp_day = "2026-09-10" if oid == EXPIRED_LOT_ORG else f"2026-09-{rng.randint(5, 25):02d}"
        for lid, bought, exp, bal in [
            (f"lot_{oid}_p1", exp_day.replace("2026", "2025"), exp_day, old),
            (f"lot_{oid}_p2", "2026-06-15", "2027-06-15", recent),
        ]:
            lots.append((lid, oid, "purchased", bought, exp, bal, bal))
            active.append([lid, exp, bal, "purchased"])
        threshold, target = round(month_spend * 0.1, 2), round(month_spend * 0.5, 2)
        reload_no = 0
        for d in range(1, 31):
            day = f"2026-09-{d:02d}"
            # expire lots whose date has passed (end of their expiry day)
            for lot in active:
                if lot[1] < day and lot[2] > 0:
                    if not (oid == EXPIRED_LOT_ORG and lot[0].endswith("_p1")):
                        entry(oid, lot[1], "expiration", lot[0], -lot[2])
                        lot[2] = 0.0
            purchased_bal = sum(l[2] for l in active if l[3] == "purchased" and l[1] >= day)
            if auto_reload and purchased_bal < threshold and target > 0:
                reload_no += 1
                lid = f"lot_{oid}_ar{reload_no}"
                amt = round(target - purchased_bal, 2)
                lots.append((lid, oid, "purchased", day, "2027-" + day[5:], amt, 0.0))
                entry(oid, day, "purchase", lid, amt)
                active.append([lid, "2027-" + day[5:], amt, "purchased"])
            need = daily_usage.get((oid, day), 0.0)
            # waterfall: included credits first, then purchased lots, earliest expiry first
            order = sorted(active, key=lambda l: (l[3] != "included", l[1]))
            for lot in order:
                if need <= 1e-9:
                    break
                usable = lot[1] >= day or (oid == EXPIRED_LOT_ORG and lot[0].endswith("_p1"))
                if lot[2] > 0 and usable:
                    take = min(need, lot[2])
                    lot[2] -= take
                    need -= take
                    entry(oid, day, "consumption", lot[0], -take)
            if need > 1e-9:
                entry(oid, day, "consumption", "unfunded", -need)   # served with no credit left
        for lot in active:                              # included credits expire at month end
            if lot[3] == "included" and lot[2] > 1e-9:
                entry(oid, "2026-09-30", "expiration", lot[0], -lot[2])
                lot[2] = 0.0

    # ---- Claude app subscriptions (for subscription unit economics) ----------------------
    plan_price = {"pro_monthly": 20.0, "pro_annual": 200 / 12, "max_5x": 100.0, "max_20x": 200.0,
                  "team_standard": 25.0, "team_premium": 125.0}
    plan_mix = {"pro_monthly": 0.38, "pro_annual": 0.22, "max_5x": 0.13, "max_20x": 0.07,
                "team_standard": 0.15, "team_premium": 0.05}
    median_ratio = {"pro_monthly": 0.55, "pro_annual": 0.6, "max_5x": 1.1, "max_20x": 1.4,
                    "team_standard": 0.45, "team_premium": 0.9}
    subs = []
    n_subs = max(5000, n_requests // 40)
    plans_list, weights = list(plan_mix), list(plan_mix.values())
    for s in range(1, n_subs + 1):
        p = rng.choices(plans_list, weights=weights)[0]
        ratio = rng.lognormvariate(math.log(median_ratio[p]), 1.15)
        usage = round(plan_price[p] * ratio, 2)
        code_share = round(min(1.0, rng.betavariate(2, 3) * (1.6 if p.startswith("max") else 1.0)), 3)
        subs.append((f"sub_{s:07d}", p, PERIOD, round(plan_price[p], 2), usage, code_share))

    write(SEEDS / "raw_orgs.csv", ["org_id", "org_name", "segment", "channel", "linked_plan",
                                   "team_standard_seats", "team_premium_seats"], orgs)
    write(SEEDS / "raw_price_book.csv", ["model", "pricing_tier", "input_usd_per_mtok", "output_usd_per_mtok",
                                         "cache_write_5m_usd_per_mtok", "cache_write_1h_usd_per_mtok",
                                         "cache_hit_usd_per_mtok", "geo_eligible"], PRICE_BOOK)
    write(SEEDS / "raw_invoices.csv", ["invoice_id", "org_id", "billing_period", "invoice_date", "due_date",
                                       "invoice_amount"], invoices)
    write(SEEDS / "raw_invoice_lines.csv", ["invoice_id", "line_item", "line_amount"], lines)
    write(SEEDS / "raw_payments.csv", ["payment_id", "invoice_id", "org_id", "payment_date", "payment_amount",
                                       "status"], payments)
    write(SEEDS / "raw_gl_revenue.csv", ["journal_entry_id", "org_id", "billing_period", "revenue_amount"], gl)
    write(SEEDS / "raw_partner_settlements.csv", ["settlement_id", "org_id", "channel", "billing_period",
                                                  "ccus_billed", "settlement_amount_usd"], settlements)
    write(SEEDS / "raw_credit_lots.csv", ["lot_id", "org_id", "lot_type", "acquired_on", "expires_on",
                                          "original_amount", "opening_balance"], lots)
    write(SEEDS / "raw_credit_ledger.csv", ["entry_id", "org_id", "entry_date", "entry_type", "lot_id",
                                            "amount"], ledger)
    write(RAW / "subscriptions.csv", ["subscription_id", "plan", "billing_period", "monthly_price_usd",
                                      "api_equivalent_usage_usd", "claude_code_share"], subs)
    print(f"{len(all_requests):,} API requests ({len(dups):,} duplicates) across {len(orgs)} orgs; "
          f"{len(invoices)} invoices, {len(settlements)} partner settlements, {len(lots)} credit lots, "
          f"{len(ledger):,} ledger entries, {len(subs):,} subscriptions")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--requests", type=int, default=1_000_000)
    ap.add_argument("--seed", type=int, default=7)
    a = ap.parse_args()
    main(a.requests, a.seed)
