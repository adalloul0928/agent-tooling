---
name: life-os-voice
description: >-
  Build or refine Aren's bounded voice profile from representative sent Gmail/iMessage samples and his corrections to drafts, with separate text, personal-email, professional-email, acknowledgement, sensitive-message, and recipient-specific modes. Use for "learn my writing style", "update my voice profile", "make drafts sound more like me", or after Aren substantially edits a Life OS draft. Do not copy entire conversations or silently change sensitive tone rules.
---

# Life OS Voice

Learn compact, reviewable writing rules rather than turning private history into a permanent prompt corpus.

Read `../../runtime/references/workflow-contract.md`. The machine-local `voice-profile.md` is the only durable voice artifact; do not place raw samples in Obsidian or SQLite.

## Step 1 — choose a bounded sample

Obtain Aren's permission for the account/channel and date range. Prefer 20–40 representative sent messages per mode, excluding automated mail, one-word noise, quoted thread history, secrets, medical/financial content, and conversations involving children or especially sensitive circumstances unless Aren explicitly includes them.

For iMessage, read only after Full Disk Access is verified. For Gmail, use sent mail from the connected account. Analyze transiently.

## Step 2 — extract rules, not mimicry

Identify sentence length, directness, warmth, greetings/sign-offs, contractions, punctuation, emoji use, humor, apology style, request/commitment phrasing, and differences by channel/relationship. Preserve uncertainty where the sample is mixed.

Never infer beliefs, feelings, or promises. Do not imitate another participant's writing.

## Step 3 — propose a profile update

Produce small rule changes under the relevant mode with a rationale and sample category, not raw private text. Recipient-specific overrides require Aren's review. Sensitive-message rules always remain approval-gated.

## Step 4 — learn from corrections

When Aren edits a draft, compare proposed versus approved wording. Suggest one or two generalizable changes only when the edit reflects stable style rather than message-specific facts. Record the dated rule after approval.

## Step 5 — canary

Generate one synthetic or consented example in each updated mode. Aren must judge whether it sounds like him before the profile is considered ready. Do not send the canaries.
