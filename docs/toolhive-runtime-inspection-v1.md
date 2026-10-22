# ToolHive runtime inspection v1

This is a read-only, bounded adapter for the local `thv` CLI. It calls only:

- `thv version --format json`
- `thv status <workload-name> --format json`
- `thv logs <workload-name>` with optional `--proxy`, never `--follow`

The pinned primary ToolHive source used for this contract is commit `5b669870017ee4b1ea39ea1b95a03f4c5b47aeab`:

- [version command](https://raw.githubusercontent.com/stacklok/toolhive/5b669870017ee4b1ea39ea1b95a03f4c5b47aeab/cmd/thv/app/version.go)
- [version JSON type](https://raw.githubusercontent.com/stacklok/toolhive/5b669870017ee4b1ea39ea1b95a03f4c5b47aeab/pkg/versions/version.go)
- [status command](https://raw.githubusercontent.com/stacklok/toolhive/5b669870017ee4b1ea39ea1b95a03f4c5b47aeab/cmd/thv/app/status.go)
- [logs command](https://raw.githubusercontent.com/stacklok/toolhive/5b669870017ee4b1ea39ea1b95a03f4c5b47aeab/cmd/thv/app/logs.go)
- [workload-name validation](https://raw.githubusercontent.com/stacklok/toolhive/5b669870017ee4b1ea39ea1b95a03f4c5b47aeab/pkg/workloads/types/validate.go)

`version --format json` emits `version`, `commit`, `build_date`, `go_version`, and `platform`. `status --format json` emits `name`, `status`, `health`, `package`, `url`, `port`, `transport`, `proxy_mode`, `group`, and `uptime`; fields marked optional by ToolHive remain optional here.

The adapter treats `status` and `health` as ToolHive-reported evidence only. A `running` status is never converted into a client-health assertion. It distinguishes an unavailable CLI from an unsupported JSON response, caps JSON before parsing, redacts and bounds diagnostics and log snapshots, validates ToolHive's workload grammar before invoking the CLI, and checks cancellation before and after the injected command runner. Streaming logs remain outside this initial contract.

The existing runtime provider now uses the structured version probe and
advertises only the implemented status/log inspection capabilities. The app
coalesces refreshes and reuses one version result for workload listing. A failed
list remains a visible diagnostic, rather than an authoritative zero-workload
result. A launched CLI with an unsupported response is distinct from a missing
CLI.

Settings lists discovered workloads with an Inspect action. The sheet displays
reported status/health and workload details, with separate user-requested
workload/proxy log snapshots. Closing the sheet cancels its tasks. Log output is
bounded and selectable, and truncation is explicit. No log stream starts on
open, and no start/stop/restart/install operation is exposed by this packet.

The injected runner fixtures and off-screen light/dark renders do not establish
live compatibility with a particular installed ToolHive release. Streaming,
reviewed lifecycle actions and real-runtime qualification remain H1/H2 gates.
