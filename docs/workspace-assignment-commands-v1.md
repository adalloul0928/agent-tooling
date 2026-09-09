# Shared assignment commands

`WorkspaceApplicationService.previewAssignmentBatch` and
`applyAssignmentBatch` share one portable intent command. They are available to
trusted local callers; the MCP interface remains request/queue-only. This packet
does not execute a native install or report an installation receipt.

## Everyday batch and Apply once

`WorkspaceAssignmentBatchCommand.assign` captures selected artifacts and explicit
app/scope/project/device destinations. `applyPresetOnce` captures a preset's
revision and complete current membership, then expands that snapshot into
independent contributions. A preset must contain assignable artifacts; selecting
a native plugin means selecting its owning root. Child extraction is rejected.

The command includes an expected workspace revision, idempotency key, explicit
contribution additions and explicit contribution IDs to remove. Preview shows
the exact additions, removals and remaining reasons in canonical order. A second
manual request for the same artifact, destination and reason is rejected rather
than creating an indistinguishable duplicate. Device lists are compared in
canonical order; `nil` (all enrolled devices) and `[]` (none) remain distinct.

Different reasons can require the same item at the same destination. Removing
one contribution preserves the others. An explicit batch may remove an old
contribution and add its replacement atomically. The everyday command can add
manual or reviewed preset reasons; migration and project-declaration reasons
come from their own workflows.

The writer rechecks preset revision/membership and document validity inside the
same transaction that saves the revision, head and command receipt. A stale
review cannot overwrite a newer head. Replaying the exact saved command returns
its historical receipt even after later edits or restart. Reusing its key with
different input is a conflict.

Changing preset membership later does not add or remove the contributions from
an earlier Apply once. Linked preset subscriptions are separate future P1 work.
Portable metadata, native deployment files and device observations remain
separate: this service changes the first and leaves the latter two untouched.

## Integration still required

The shared Library/Project/onboarding assignment sheet must retain the reviewed
command rather than recreate IDs on retry. It must resolve target capabilities
and present native operation plans/results independently from saved intent.
Current assignment command fixtures exercise the real revision store, including
independent reasons, replacement, preset changes, replay, stale input and
whole-plugin protection. They are not packaged assignment-flow or native
consumption evidence.
