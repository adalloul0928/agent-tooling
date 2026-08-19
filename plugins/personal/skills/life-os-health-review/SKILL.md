---
name: life-os-health-review
description: >-
  Review Aren's read-only Oura and Apple Health trends alongside his stated energy and workload, then suggest planning adjustments without diagnosing or changing health data. Use for "health review", "how has my sleep or readiness been", "factor recovery into my week", or the health section of a weekly/monthly review. Do not provide medical diagnosis, treatment, or emergency guidance from device data.
---

# Life OS Health Review

Use health signals as context for planning, never as a medical authority.

Read `../../runtime/references/workflow-contract.md` and use `../../runtime/templates/health-review.md` for a durable review.

## Step 1 — establish provenance and freshness

Run `lifeos doctor`, synchronize the requested bounded Oura range, and ingest only deliberately exported Apple Health metrics. Report missing dates, devices, or sources. Do not merge apparently similar metrics without naming their source and unit.

## Step 2 — use trends

Analyze multi-day or multi-week sleep, readiness, resting heart rate, activity, HRV, workouts, and the user's own reported energy where available. Avoid treating one score as a directive. Compare like periods and note confounders rather than making causal claims.

## Step 3 — translate to planning

Offer bounded suggestions such as reducing nonessential load, protecting sleep opportunity, scheduling recovery, or placing demanding work during observed high-energy periods. Frame them as options. The user's stated experience outranks a device score.

## Safety boundary

Never diagnose, interpret symptoms as disease, change health records, or recommend medication. If Aren describes urgent or concerning symptoms, advise appropriate professional or emergency help independent of wearable data.

## Output

Include data availability, trend summary, workload implications, uncertainties, and questions worth noticing. Keep granular health records out of general communication reviews.
