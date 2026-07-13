# GA4 Query Recipes for analytics-mcp

Reference parameter shapes for the `run_report` and `run_funnel_report` tools on Google's official analytics-mcp server. Substitute the IAWIS property ID from SKILL.md for `XXXXXXXXX` below.

The MCP server uses the Google Analytics Data API v1. Date strings support `today`, `yesterday`, `NdaysAgo`, or `YYYY-MM-DD`.

**Important — `metrics` and `dimensions` are plain string arrays**, e.g. `metrics=["totalRevenue"]` and `dimensions=["sessionDefaultChannelGroup"]` — *not* `{"name": ...}` objects. `date_ranges`, `order_bys`, and `dimension_filter` are objects, with the shapes shown below.

## Tier 1 — Money (with week-over-week comparison)

```
run_report(
  property_id="properties/XXXXXXXXX",
  date_ranges=[
    {"start_date": "7daysAgo",  "end_date": "yesterday", "name": "current"},
    {"start_date": "14daysAgo", "end_date": "8daysAgo",  "name": "prior"}
  ],
  metrics=["totalRevenue", "transactions", "sessions",
           "sessionConversionRate", "averagePurchaseRevenue"]
)
```

The response will include a `date_range` column letting you split current vs prior.

## Tier 2 — Acquisition by channel group

```
run_report(
  property_id="properties/XXXXXXXXX",
  date_ranges=[
    {"start_date": "7daysAgo",  "end_date": "yesterday", "name": "current"},
    {"start_date": "14daysAgo", "end_date": "8daysAgo",  "name": "prior"}
  ],
  dimensions=["sessionDefaultChannelGroup"],
  metrics=["sessions", "totalRevenue", "transactions", "sessionConversionRate"],
  order_bys=[{"metric": {"metric_name": "totalRevenue"}, "desc": true}],
  limit=10
)
```

For source/medium drill-down, swap dimension: `dimensions=["sessionSourceMedium"]`.
For campaigns: `dimensions=["sessionCampaignName"]`.

## Tier 3 — Top landing pages

```
run_report(
  property_id="properties/XXXXXXXXX",
  date_ranges=[{"start_date": "7daysAgo", "end_date": "yesterday"}],
  dimensions=["landingPagePlusQueryString"],
  metrics=["sessions", "sessionConversionRate", "totalRevenue",
           "engagementRate"],
  order_bys=[{"metric": {"metric_name": "sessions"}, "desc": true}],
  limit=10
)
```

## Tier 3 — Device split

```
run_report(
  property_id="properties/XXXXXXXXX",
  date_ranges=[
    {"start_date": "7daysAgo",  "end_date": "yesterday", "name": "current"},
    {"start_date": "14daysAgo", "end_date": "8daysAgo",  "name": "prior"}
  ],
  dimensions=["deviceCategory"],
  metrics=["sessions", "sessionConversionRate", "totalRevenue"]
)
```

## Tier 3 — Purchase funnel

```
run_funnel_report(
  property_id="properties/XXXXXXXXX",
  date_ranges=[{"start_date": "7daysAgo", "end_date": "yesterday"}],
  funnel_steps=[
    {"name": "View item",      "filter_expression": {"funnel_event_filter": {"event_name": "view_item"}}},
    {"name": "Add to cart",    "filter_expression": {"funnel_event_filter": {"event_name": "add_to_cart"}}},
    {"name": "Begin checkout", "filter_expression": {"funnel_event_filter": {"event_name": "begin_checkout"}}},
    {"name": "Purchase",       "filter_expression": {"funnel_event_filter": {"event_name": "purchase"}}}
  ]
)
```

A zero at a funnel step is ambiguous — it can mean a tracking issue **or** simply a low-volume week where that step genuinely had no events. Never call it a tracking issue from the funnel alone. Confirm with the purchase-liveness check below and the Shopify cross-check (`references/shopify-crosscheck.md`). For IAWIS, `view_item` / `add_to_cart` / `begin_checkout` fire from the storefront's GTM container and `purchase` fires from the Shopify-hosted checkout — all four confirmed working as of May 2026.

## Purchase-liveness check — run before ever claiming `purchase` is broken

A single quiet week showing 0 purchases is normal at this volume. Before writing *anything* about `purchase` being missing or broken, confirm whether the event has fired at all recently with a 90-day lookback:

```
run_report(
  property_id="properties/XXXXXXXXX",
  date_ranges=[{"start_date": "90daysAgo", "end_date": "yesterday"}],
  dimensions=["eventName"],
  metrics=["eventCount", "totalRevenue"],
  dimension_filter={"filter": {"field_name": "eventName",
    "string_filter": {"match_type": "EXACT", "value": "purchase"}}}
)
```

- Non-zero `purchase` count over 90 days → the event works. A 0-purchase week is a quiet-week / business signal, not a tracking break. Do not say tracking is broken.
- Zero rows across 90 days **and** the Shopify cross-check shows web orders in that period → a genuine tracking gap; report it.

## 8-week trend (feeds the report's trend chart)

One extra pull per run: weekly `sessions` and `totalRevenue` for the last ~8 weeks. Feeds the two area charts in the report's "The Numbers" section.

```
run_report(
  property_id="properties/XXXXXXXXX",
  date_ranges=[{"start_date": "56daysAgo", "end_date": "yesterday"}],
  dimensions=["isoYearIsoWeek"],
  metrics=["sessions", "totalRevenue"],
  order_bys=[{"dimension": {"dimension_name": "isoYearIsoWeek"}}]
)
```

`isoYearIsoWeek` returns ISO calendar weeks (e.g. `202618`), oldest first. These are calendar weeks, so the most recent row may be a partial week — that's fine for a trend line. If the property has fewer than 8 weeks of data, chart whatever rows come back.

## Tier 4 — Top cities

```
run_report(
  property_id="properties/XXXXXXXXX",
  date_ranges=[{"start_date": "7daysAgo", "end_date": "yesterday"}],
  dimensions=["city", "region"],
  metrics=["totalRevenue", "sessions", "transactions"],
  order_bys=[{"metric": {"metric_name": "totalRevenue"}, "desc": true}],
  limit=10
)
```

## Tier 4 — New vs returning

```
run_report(
  property_id="properties/XXXXXXXXX",
  date_ranges=[{"start_date": "7daysAgo", "end_date": "yesterday"}],
  dimensions=["newVsReturning"],
  metrics=["sessions", "sessionConversionRate", "totalRevenue"]
)
```

## Notes & gotchas

- The MCP server estimates large result sizes — if a query would return thousands of rows it'll warn first. Keep `limit` set on dimensional queries.
- Sampling kicks in on long date ranges with high cardinality dimensions. For weekly reports this isn't usually a problem.
- `metrics` and `dimensions` must be plain string arrays (e.g. `["sessions"]`). Passing `{"name": "sessions"}` objects will fail.
- `sessionConversionRate` = sessions with at least one **key event** ÷ total sessions — meaningful only if the *right* events are key events. As of May 2026 this property has `scroll_depth_25` and `scroll_depth_50` wrongly marked as key events, which inflates the metric badly (it ends up measuring scrolling, not buying). Until that is corrected in GA4 admin, treat `sessionConversionRate` as unreliable — compute conversion yourself as `transactions ÷ sessions`.
- For the headless wetinseattle.com setup specifically: pre-checkout events (`view_item`, `add_to_cart`, `begin_checkout`) fire from the storefront's own GTM container, and `purchase` fires from the Shopify-hosted checkout — both paths confirmed working (May 2026). GA4 records website orders only; Shopify POS / in-person sales never appear in it. Reconcile via `references/shopify-crosscheck.md`.
