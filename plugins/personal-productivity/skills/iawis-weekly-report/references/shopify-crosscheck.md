# Shopify Order Cross-Check

GA4 cannot, by itself, distinguish a **tracking break** from a **genuinely quiet week** — both show up as low or zero revenue. This cross-check pulls IAWIS's *actual* Shopify orders for the reported week and splits them by sales channel, giving the report a ground-truth number to reconcile GA4 against.

Run it every week, as step 3 of the procedure, after the GA4 tiers are pulled.

## Why this matters

- GA4 records a `purchase` **only for website orders**. Shopify **POS / in-person** sales (markets, pop-ups) and **manual draft** orders never reach GA4 — and that is correct behavior.
- So Shopify's *total* order count will always be ≥ GA4's purchase count. The number GA4 should match is Shopify's **web** orders only — never the total.
- A week can show $0 in GA4 and still be a real sales week if the orders were placed in person.
- This is exactly the trap the 2026-05-16 report fell into: it compared GA4 against all Shopify activity and read a quiet web week as "revenue tracking broken." It was not.

## The recipe

Credentials live in the IAWIS storefront repo's `.env.local`. The block below sources them, computes the same 7-day windows the GA4 queries use, and prints orders bucketed by channel for this week and last week. It uses macOS / BSD `date` (Aaron's machine).

```bash
ENV_FILE="${IAWIS_STOREFRONT_REPO:?Set IAWIS_STOREFRONT_REPO to the storefront checkout}/.env.local"
if [ ! -f "$ENV_FILE" ]; then
  echo "SHOPIFY CROSS-CHECK SKIPPED: $ENV_FILE not found — report 'Shopify cross-check unavailable'."
else
  set -a; source "$ENV_FILE" 2>/dev/null; set +a
  D="$SHOPIFY_STORE_DOMAIN"; T="$SHOPIFY_ADMIN_ACCESS_TOKEN"; V="2025-10"
  if [ -z "$D" ] || [ -z "$T" ]; then
    echo "SHOPIFY CROSS-CHECK SKIPPED: store domain or admin token missing — report 'Shopify cross-check unavailable'."
  else
    OFF=$(date +%z | sed 's/\(..\)$/:\1/')                  # local UTC offset, e.g. -07:00
    CUR_MIN=$(date -v-7d +%F);  CUR_MAX=$(date +%F)          # this week  [min, max)
    PRI_MIN=$(date -v-14d +%F); PRI_MAX=$(date -v-7d +%F)    # prior week [min, max)
    H="X-Shopify-Access-Token: $T"
    for W in "this week:$CUR_MIN:$CUR_MAX" "prior week:$PRI_MIN:$PRI_MAX"; do
      LABEL=${W%%:*}; REST=${W#*:}; MN=${REST%%:*}; MX=${REST#*:}
      echo "=== $LABEL ($MN .. $MX) ==="
      curl -s -H "$H" "https://$D/admin/api/$V/orders.json?status=any&limit=250&created_at_min=${MN}T00:00:00${OFF}&created_at_max=${MX}T00:00:00${OFF}&fields=created_at,total_price,source_name" \
      | python3 -c '
import sys, json, collections
orders = json.load(sys.stdin).get("orders", [])
def cat(s):
    s = str(s)
    if s in ("quick_sale", "pos"): return "POS/in-person"
    if s == "shopify_draft_order": return "draft(manual)"
    if s == "web" or s.isdigit(): return "web"
    return "other"
n = collections.Counter()
rev = collections.defaultdict(float)
for o in orders:
    k = cat(o.get("source_name"))
    n[k] += 1
    rev[k] += float(o.get("total_price") or 0)
for k in ("web", "POS/in-person", "draft(manual)", "other"):
    if n[k]:
        print(f"  {k}: {n[k]} orders  ${rev[k]:,.2f}")
total = sum(n.values())
wn = n["web"]
wr = rev["web"]
print(f"  TOTAL: {total} orders")
print(f"  >>> WEB: {wn} orders  ${wr:,.2f}  <-- GA4 purchase count/revenue should land near this")
'
    done
  fi
fi
```

## Reading the result

Compare GA4 Tier 1 (web `purchase` count and `totalRevenue`) against the **WEB** line for the same week:

| GA4 web purchases | Shopify web orders | Verdict |
|---|---|---|
| ~80–95% of Shopify web | > 0 | **Healthy.** Normal client-side loss (ad blockers, consent, Safari ITP). Report revenue as-is. |
| ≈ 0 | ≈ 0 | **Quiet week, not a break.** Report it as a low-traffic / low-sales week. If POS orders were high, say the business sold in person. |
| ≈ 0 (or far below) | clearly > 0 | **Genuine tracking break.** Lead the report with it; treat GA4 revenue as undercounted. |
| consistently 50–75% of Shopify web | > 0 | **Partial degradation** — worth a flag, not a five-alarm headline. |

Never headline a tracking break unless this table puts you in row 3 (or row 4). A quiet week is the most common cause of low GA4 revenue and is a business signal, not a bug.

If the recipe printed `SHOPIFY CROSS-CHECK SKIPPED`, write "Shopify cross-check unavailable this week" in the report and do not assert anything about tracking being broken.
