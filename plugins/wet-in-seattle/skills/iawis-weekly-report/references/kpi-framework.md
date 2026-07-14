# IAWIS KPI Framework

Reference for the four metric tiers used in the weekly report. Each tier answers a different question.

## Tier 1 — Money: did the business move this week?

| Metric | GA4 name | Why it matters for IAWIS |
|---|---|---|
| Revenue | `totalRevenue` | The number. Everything else is a leading indicator. |
| Transactions | `transactions` | Order volume — separates "fewer big buyers" from "lots of small buyers." |
| Sessions | `sessions` | Top of funnel. Low conversion + high sessions is a different problem than high conversion + low sessions. |
| Conversion rate | `sessionConversionRate` | The efficiency number. DTC streetwear benchmark is roughly 1.5–3%. Premium positioning typically lands closer to 1.5–2%. |
| AOV | `averagePurchaseRevenue` | Premium positioning lives or dies here. If AOV drifts down, the discount-driven traffic mix has crept up. |

**What "good" looks like for IAWIS**: revenue and transactions both up week-over-week, conversion rate stable or up, AOV stable or up. If revenue is up but AOV is down, you're growing on volume — fine, but it means margin pressure unless cost is dropping.

**Web vs total sales**: `totalRevenue` here is *website* revenue only. IAWIS also sells in person (markets, pop-ups) through Shopify POS — those orders never appear in GA4. The weekly report covers the website; reconcile against Shopify (step 3) so a strong in-person week is not misread as a weak business week.

## Tier 2 — Acquisition: where did it come from?

| Dimension | Why it matters |
|---|---|
| `sessionDefaultChannelGroup` | First-pass attribution: Organic Search, Direct, Paid Social, Organic Social, Email, Referral, Paid Search. The simplest view of where revenue is coming from. |
| `sessionSourceMedium` | Drill-down inside a channel. `instagram / cpc` (paid) vs `instagram / referral` (organic) tells very different stories. |
| `sessionCampaignName` | UTM-tagged campaigns. If this comes back mostly `(not set)`, that's a finding — campaigns aren't being tagged consistently. |
| `firstUserDefaultChannelGroup` | How they *first* found the brand vs how they came back this session. Discovery vs return. |

**Concentration risk**: a healthy mix has no single channel >60% of revenue. Heavy paid social concentration is a fragility risk — CPMs go up, revenue craters. If paid social is >60%, that should be in the Actions section as something to diversify.

**Branded vs non-branded**: organic search with branded keywords (people Googling "wetinseattle" or "it's always wet in seattle") is essentially demand capture, not discovery. If branded organic is the bulk of organic, the SEO investment isn't pulling new audience.

## Tier 3 — Behavior: why is it converting (or not)?

| Dimension / report | Why it matters |
|---|---|
| `landingPagePlusQueryString` × sessions × conversion rate | Where people land vs where they buy. PDPs converting higher than the homepage is normal. If the homepage is converting higher, the collection/category browse experience isn't pulling people through. |
| `deviceCategory` × conversion rate | Shopify stores almost always have a desktop > mobile conversion gap. A *widening* gap signals mobile UX regressed (slow LCP, broken cart button, etc.). |
| Funnel: view_item → add_to_cart → begin_checkout → purchase | The leak detector. Add-to-cart-but-no-checkout = price/shipping shock. Begin-checkout-but-no-purchase = payment friction or trust issue. |
| `engagementRate` | GA4's replacement for the inverse of bounce rate. <60% engagement on a top landing page is worth a closer look. |

**Funnel benchmark intuition**: roughly, view_item → add_to_cart should be 5–15%, add_to_cart → begin_checkout should be 30–50%, begin_checkout → purchase should be 50–80%. Below these and you have a problem at that step.

## Tier 4 — Audience & Geo: who is buying?

| Dimension | Why it matters |
|---|---|
| `city`, `region` × revenue | Pacific Northwest concentration is part of the brand thesis. If Seattle / WA isn't in the top regions, the "local roots" positioning isn't doing the work it's supposed to do. |
| `newVsReturning` | Returning buyer mix is the loyalty signal. New-only growth is fragile — it means the brand isn't building repeat customers. Healthy DTC has 20–40% returning sessions, and returning sessions usually convert 2–3× new sessions. |
| `userAgeBracket`, `userGender` | Audience composition. Only available with Google signals enabled — if blank, note that signals aren't on. |

## Cross-cutting flags

These aren't a tier but should surface when present:

- **Tracking sanity**: 0 transactions in a week is *not* automatically a tracking issue — at IAWIS's volume and ~1–2% conversion rate, a quiet week genuinely produces 0 web orders. Flag a tracking issue only when the Shopify cross-check (step 3) shows web orders GA4 failed to record. A sudden 100% drop in a *base* metric (sessions, page_view) is still worth flagging. And remember GA4 sees website sales only — Shopify POS / in-person orders are invisible to it by design, so $0 GA4 revenue ≠ $0 business.
- **Bot traffic**: if direct traffic spikes 5×+ with no corresponding conversion lift, suspect bot traffic
- **Holiday / seasonality**: if the week contains a US holiday, ecommerce patterns shift — note the holiday context before interpreting deltas
