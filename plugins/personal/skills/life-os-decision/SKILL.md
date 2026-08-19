---
name: life-os-decision
description: >-
  Capture, examine, and later revisit a meaningful personal decision with options, rationale, tradeoffs, expected outcome, source evidence, and a review trigger. Use for "log this decision", "help me decide", "decision journal", or "was that decision right". Do not use for trivial preferences or pretend hindsight proves a choice was wrong.
---

# Life OS Decision

Make decisions legible enough to learn from without replacing Aren's judgment.

Read `../../runtime/references/workflow-contract.md` and use `../../runtime/templates/decision.md`.

## Capture

Record:

- the decision in one sentence;
- context and explicit constraints;
- credible options, including doing nothing;
- rationale and tradeoffs;
- what would change the decision;
- expected outcome and confidence;
- a concrete revisit trigger or date;
- source/project references.

Distinguish Aren's values and facts from the assistant's inference. For a decision already made, preserve the contemporaneous rationale rather than rewriting it with hindsight.

## Route

Write one Obsidian decision note at the configured canonical path and record the normalized decision with `lifeos decision-record`. Create a TickTick review task only when a revisit date is real and explicitly accepted.

## Revisit

Compare expected and actual outcomes, identify which assumptions held, and capture a reusable lesson. Judge process quality separately from outcome luck. Update the same note only after Aren confirms the exact edit; pass `--overwrite --confirmed` to the runtime after that confirmation. Update the normalized decision using its existing ID; do not create a parallel retrospective.
