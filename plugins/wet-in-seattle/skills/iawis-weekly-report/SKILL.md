---
name: iawis-weekly-report
description: Generate a weekly Google Analytics report for It's Always Wet In Seattle (IAWIS / wetinseattle.com). Use this skill whenever Aaron asks for a weekly site report, weekly GA report, weekly traffic report, "how is the site doing", "how is IAWIS doing", IAWIS analytics, wetinseattle analytics, conversion analysis, channel performance, or any week-over-week site analysis — even if he doesn't explicitly say "report" or "skill". Also use when he asks to "run the weekly", "do the weekly thing", or "pull the numbers". Requires the analytics-mcp server (Google's official Google Analytics MCP) to be configured.
---

# IAWIS Weekly Report

Generate a weekly Google Analytics report for **It's Always Wet In Seattle** (IAWIS), a Seattle-based premium streetwear brand at wetinseattle.com. Headless Shopify storefront on Next.js / Vercel.

## Property

- **Brand**: It's Always Wet In Seattle (IAWIS)
- **Domain**: wetinseattle.com
- **GA4 Property ID**: `509725408`
- **Currency**: USD
- **Architecture note**: Headless Shopify (Next.js on Vercel). Customer accounts on account.wetinseattle.com — may be a separate data stream worth noting if it appears in data.
- **GA4 sees WEBSITE sales only**: GA4 records a `purchase` only for orders placed on the website. Shopify **POS / in-person** sales (markets, pop-ups — `source_name` `quick_sale` or `pos`) and **manual draft** orders never reach GA4 — that is correct, not a bug. A week with $0 GA4 revenue can still be a week with real in-person sales. Never judge tracking without reconciling against Shopify first (step 3).
- **Shopify cross-check source**: set `$IAWIS_STOREFRONT_REPO` to the IAWIS storefront checkout. Its `.env.local` holds `SHOPIFY_STORE_DOMAIN` and `SHOPIFY_ADMIN_ACCESS_TOKEN`. The website sales channel is `source_name` `6914209` (numeric) or `web`.

If the property ID placeholder hasn't been filled in, call `get_account_summaries` on the analytics-mcp server, find the IAWIS property, and ask Aaron to confirm before continuing.

## analytics-mcp authentication

The `wet-in-seattle` plugin starts `analytics-mcp` through Doppler. Local setup
expects Doppler project `agent-tooling`, config `prd`, with these keys:

- `GOOGLE_APPLICATION_CREDENTIALS`: the path to the local ADC JSON file;
- `GOOGLE_PROJECT_ID`: the Google Cloud project used by analytics-mcp.

The plugin requests only those two keys when the server starts. Doppler login,
Google ADC, and the credential file remain machine-local.

The MCP server's Google credentials expire periodically. If any GA4 tool call returns one of:

- `503 Reauthentication is needed` — access token expired
- `403 ACCESS_TOKEN_SCOPE_INSUFFICIENT` — token refreshed without the Analytics scope
- browser shows **"This app is blocked. This app tried to access sensitive info in your Google Account."** — gcloud used the wrong (default) OAuth client and the `wetinseattle.com` Workspace blocked it

…run this exact command (**both flags matter** — plain `gcloud auth application-default login` will NOT work):

```bash
gcloud auth application-default login \
  --scopes=https://www.googleapis.com/auth/analytics.readonly,https://www.googleapis.com/auth/cloud-platform \
  --client-id-file="$IAWIS_GCLOUD_CLIENT_ID_FILE"
```

Sign in as `aren@wetinseattle.com`. After "Credentials saved to file: …",
reconnect `analytics-mcp` in the active client (it caches credentials at startup
and won't see the new ones otherwise), then retry the failed query. Full
background, error → cause cheat sheet, and recovery if the OAuth client JSON is
lost: `references/analytics-mcp-auth.md`.

## Procedure

When triggered, run this workflow in order.

### 1. Set the date ranges
- **This week**: last 7 complete days (end_date = `yesterday`, start_date = `7daysAgo`). Never include today — partial days skew rates.
- **Prior week**: the 7 days immediately before that (start_date = `14daysAgo`, end_date = `8daysAgo`)
- Use these same windows across all queries so deltas are apples-to-apples.

### 2. Pull the metric tiers
Run separate `run_report` calls — one per tier, plus one more for the 8-week trend. Combining them returns too much data and dimensions/metrics don't always mix cleanly. See `references/ga4-queries.md` for exact parameter shapes.

- **Tier 1 — Money**: totalRevenue, transactions, sessions, sessionConversionRate, averagePurchaseRevenue. Both date ranges.
- **Tier 2 — Acquisition**: revenue and sessions by `sessionDefaultChannelGroup`, top 10. If anything notable, drill into `sessionSourceMedium`.
- **Tier 3 — Behavior**: top 10 landing pages by sessions with their conversion rate and revenue. Device split (`deviceCategory`). Run `run_funnel_report` for view_item → add_to_cart → begin_checkout → purchase.
- **Tier 4 — Geo**: top 10 cities by revenue, with region.
- **8-week trend**: one extra `run_report` for weekly `sessions` and `totalRevenue` over the last ~8 weeks — this feeds the trend chart in the report. See the 8-week trend query in `references/ga4-queries.md`. If the property has under 8 weeks of data, chart what exists.

### 3. Cross-check revenue against Shopify orders
GA4 by itself cannot tell a tracking break apart from a genuinely quiet week — both look like "low or zero revenue." Shopify's order records can. Run the cross-check in `references/shopify-crosscheck.md`; it pulls this week's and last week's actual Shopify orders split by sales channel (web / POS-in-person / draft).

Then reconcile:
- **GA4 web `purchase` count ≈ Shopify web orders** — GA4 normally captures ~80–95% of web orders (ad blockers, consent denials, Safari ITP all cause expected loss). Inside that band = tracking healthy.
- **GA4 web purchases ≈ 0 but Shopify web orders clearly > 0** — this, and essentially only this, is a real tracking break. Lead the report with it.
- **GA4 web purchases ≈ 0 AND Shopify web orders ≈ 0** — a quiet sales week online, not a tracking problem. If Shopify POS orders were high, the business sold in person this week — say so explicitly.
- If the cross-check can't run (missing `.env.local` or token), write "Shopify cross-check unavailable" in the report and do **not** assert a tracking break.

### 4. Detect anomalies
Compare current to prior week. Flag any of these in the report:
- Total revenue change >20% in either direction
- Conversion rate change >25% relative (e.g., 2.0% → 2.5% is +25%)
- A channel that was top-5 last week dropping out of top 5
- Mobile vs desktop conversion gap widening or narrowing >30%
- A new landing page entering the top 10 that wasn't there last week
- **Tracking sanity check**: 0 transactions is **not by itself** a tracking break. At IAWIS's ~1–2% conversion rate, a sub-300-session week can legitimately produce 0 web orders by pure chance. Call a tracking break *only* when the step 3 Shopify cross-check shows web orders that GA4 did not record. Never declare an event "missing from the property" or "broken" from a single week of GA4 data — confirm with the 90-day purchase-liveness query in `references/ga4-queries.md` and the Shopify cross-check.

### 5. Generate the report
Clone `references/report-template.html` and fill in the real data — it is a complete, self-contained HTML file (inline CSS, inline-SVG charts, no external dependencies). Keep all five sections: Headline, The Numbers, Channels, Funnel & Behavior, Actions This Week. Follow the HTML comments inside the template — they explain what each section needs and how each chart's geometry maps to data, including the anomaly banner and the degraded "not tracked" tile state.

Save the output to a file in the working directory named `iawis-weekly-YYYY-MM-DD.html` (date = the Sunday or end-date of the week reported).

## Output principles

- **Lead with money**: revenue and conversion rate first, always. Sessions without revenue context is vanity.
- **Comparisons over absolutes**: every Tier 1 number paired with a week-over-week delta and direction arrow (↑ ↓ →).
- **Three actions, not ten**: end with exactly three concrete things to do this week. Verb-led, specific.
- **Honest about flat weeks**: if nothing notable changed, say so in one line. Don't manufacture insight.
- **A quiet week is not a broken week**: low or zero web revenue is a normal outcome at this traffic volume. Report it as a business signal, not a tracking failure, unless step 3 proves otherwise.
- **Self-contained HTML**: the report is a single `.html` file — inline CSS, inline-SVG charts, no external dependencies — so it renders offline and survives being emailed or shared. Never add a CDN link, web font, image, or script.
- **Pacific Northwest lens**: when geo data is reported, name Seattle / WA / PNW concentration explicitly — the brand identity depends on local resonance.
- **Aaron's voice**: direct, no marketing-speak. "Fix the mobile add-to-cart" not "optimize the mobile user journey."

## Constraints

- The MCP server is read-only — never suggest changes to GA4 configuration, only to the business.
- Don't recommend specific ad spend changes ("increase Meta budget by $500"). Flag the trend; let Aaron decide the dollar move.
- Don't invent metrics that aren't in the pulled data. If ad cost isn't imported (no Google Ads link), say "ROAS not available" rather than estimating.
- Don't speculate on causes you can't see in the data. "Revenue dropped 30%" is fine; "Revenue dropped 30% because of the iOS update" needs evidence in the data.
- If the GA4 property has <100 sessions for the week, note that the sample is small and rates are unreliable — don't over-interpret deltas.
- Never headline "tracking is broken" or "the purchase event is missing" on GA4 data alone. That claim requires the step 3 Shopify cross-check to show web orders GA4 missed. In GA4, a quiet week and a tracking break look identical — only Shopify tells them apart.

## References

- `references/analytics-mcp-auth.md` — analytics-mcp re-authentication: the exact gcloud command (with the two flags that matter), what each common auth error means, and how to recreate the OAuth client if its JSON is lost. Read when any GA4 tool call returns an auth or "app blocked" error.
- `references/kpi-framework.md` — the four-tier KPI breakdown with metric definitions and "what good looks like" for streetwear DTC. Read when you need to explain *why* a metric matters or what benchmark to compare to.
- `references/report-template.html` — the complete, self-contained HTML report template: full styling and inline-SVG charts with realistic placeholder data. Clone and re-fill it every time you generate a report; the section-by-section writing guidance lives in its HTML comments.
- `references/ga4-queries.md` — example `run_report` and `run_funnel_report` parameter shapes for each tier, plus the purchase-liveness check and the 8-week trend query. Read when constructing MCP tool calls.
- `references/shopify-crosscheck.md` — bash recipe to pull the week's actual Shopify orders, split by sales channel, and reconcile against GA4. Read and run every time you generate a report (step 3).
