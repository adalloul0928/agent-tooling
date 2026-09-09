# Portable MCP delivery — contract v1 (AP5)

Status: mapping implemented with conformance fixtures. This maps; it does not
launch. A resolved route is not evidence the server works.

## The distinction this closes

AP1/AP2 established that a package's `mcp.json` is well-formed and that its
paths stay inside the package. That says nothing about whether any installed app
can use it. AP5 is the step that decides, per app, on this Mac.

`AgentPluginMCPRuntimeMapper.resolve` returns two lists: connections resolved for
that app, and connections refused with a named reason. A connection that cannot
be delivered is always reported. A silently missing server looks exactly like one
that was never declared, and the person has no way to tell which happened.

## Variables

Exactly two are defined, and both belong to the client:

- `${PLUGIN_ROOT}` — the installed package. Replaced on update.
- `${PLUGIN_DATA}` — the package's persistent folder. **Not** replaced on update.
  This is the whole reason the two are separate roots, and they never resolve to
  the same folder.

They are expanded in `command`, `cwd`, every argument and every environment
value. A package cannot set either as an environment variable — that is refused
at parse time — and at map time the client's own pair is merged last, so nothing
declared can shadow where the package or its data actually live.

Any other `${...}` is a refusal, never a pass-through. An unexpanded placeholder
becomes a wrong path that looks like a right one.

## Containment

Containment is checked **after** expansion and **after** following symlinks. A
link inside the package that points outside it is exactly the case a lexical
check misses, and it is covered by a fixture.

A `./`-prefixed command must exist and be executable inside the package. A bare
command is left as it is: this build does not search `PATH` and does not claim
the file exists, because that is a promise it cannot keep.

## Transport

A transport is delivered only where this Mac has recorded `TargetCapabilityEvidence`
for that surface, that component and that transport. No evidence at all is its
own refusal, distinct from "this app does not accept this transport" — the person
should be able to tell "we never checked" from "we checked and it does not".

## Remote endpoints

The endpoint is kept exactly as declared, and headers stay bound to that origin.
This build follows no redirect on the package's behalf, so a header never travels
to a host the declaration did not name. Credential-shaped headers are refused at
parse time and never reach here.

## Failure isolation

One bad server does not take its siblings with it. Each is resolved or refused on
its own, and the fixture asserts a good/bad/good triple.

## Not covered

Nothing here starts a process or opens a connection, so none of this is evidence
that a mapped server actually runs, speaks the protocol, or behaves under load.
The route is not "supported" in the sense a person would mean until a real
package has been delivered to a real client and used — which needs the packaged
pilot and a native consumption check, both still pending.
