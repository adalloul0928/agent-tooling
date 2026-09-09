# Third-party reuse register

Status: September 2026 planning and provenance record. This register records
the exact upstream snapshots reviewed for possible reuse. It is not evidence
that an upstream feature is implemented here, that a repository's distributed
skills share the repository license, or that an inspected revision matches a
current release.

Agent Tooling remains independently implemented in Swift. No competitor source
listed below has been copied into this repository as of this register. Before
copying a permissively licensed implementation, record the exact imported files,
attribution/notice requirements, and the target Swift adaptation in this file.

| Source | Pinned source | License evidence | Intended pattern, API, or schema reuse | Copied code |
| --- | --- | --- | --- | --- |
| [Skills Manager](https://github.com/xingkongliang/skills-manager) | [`10476370f6a57bdb551be328761eabbfa5d17f6c`](https://github.com/xingkongliang/skills-manager/tree/10476370f6a57bdb551be328761eabbfa5d17f6c) | [MIT](https://github.com/xingkongliang/skills-manager/blob/10476370f6a57bdb551be328761eabbfa5d17f6c/LICENSE) | Source/deployment separation, merge decisions, apply/recovery fixture scenarios, and the shared add-to-apps interaction. Port only suitable pure decisions or language-neutral fixtures into Swift. | No. |
| [Chops](https://github.com/Shpigford/chops) | [`9d379d582c8b1f77491df6aabf1049e578373845`](https://github.com/Shpigford/chops/tree/9d379d582c8b1f77491df6aabf1049e578373845) | [FSL-1.1-MIT](https://github.com/Shpigford/chops/blob/9d379d582c8b1f77491df6aabf1049e578373845/LICENSE) | Native document editing, stable selection, external-change feedback, and list/detail behavior. Do not copy the current restricted implementation or its SKILL.md-only installer. | No. |
| [CC Switch](https://github.com/farion1231/cc-switch) | [`f3b18df12007d0fd79fd8ad8d310880664015197`](https://github.com/farion1231/cc-switch/tree/f3b18df12007d0fd79fd8ad8d310880664015197) | [MIT](https://github.com/farion1231/cc-switch/blob/f3b18df12007d0fd79fd8ad8d310880664015197/LICENSE) | Source recognition on import, shared app-target control, and preserving external edits before switching instructions. Use actual lock schemas; do not adopt its snapshot sync or provider proxy. | No. |
| [MCPMate](https://github.com/loocor/mcpmate) | [`dc80b32f64788bf9513ccf241dd19708b25cce87`](https://github.com/loocor/mcpmate/tree/dc80b32f64788bf9513ccf241dd19708b25cce87) | [AGPL-3.0](https://github.com/loocor/mcpmate/blob/dc80b32f64788bf9513ccf241dd19708b25cce87/LICENSE) | Architectural reference for native-versus-proxy inspection, revision-keyed caches, and capability-change visibility. No source import without a separate compatible licensing decision. | No. |
| [ToolHive core](https://github.com/stacklok/toolhive) | [`a1f16cefb6d7e9d70495f603df9b929beb6ba7a8`](https://github.com/stacklok/toolhive/tree/a1f16cefb6d7e9d70495f603df9b929beb6ba7a8) | [Apache-2.0](https://github.com/stacklok/toolhive/blob/a1f16cefb6d7e9d70495f603df9b929beb6ba7a8/LICENSE) | Integrate supported CLI/API runtime lifecycle, logs, configuration editing, and filtering. A small helper may be adapted later with notices; do not rebuild its supervisor. | No. |
| [ToolHive Studio](https://github.com/stacklok/toolhive-studio) | [`c31b72b9b733abc0bacd85596ab68c0b9ccf1c14`](https://github.com/stacklok/toolhive-studio/tree/c31b72b9b733abc0bacd85596ab68c0b9ccf1c14) | [Apache-2.0](https://github.com/stacklok/toolhive-studio/blob/c31b72b9b733abc0bacd85596ab68c0b9ccf1c14/LICENSE) | Desktop runtime transport and lifecycle/log UI reference, used with ToolHive core through supported interfaces. | No. |
| [Skillshare](https://github.com/runkids/skillshare) | [`60e19f96d540e2b3fb1c28a68ef61d9fb8eb1897`](https://github.com/runkids/skillshare/tree/60e19f96d540e2b3fb1c28a68ef61d9fb8eb1897) | [MIT](https://github.com/runkids/skillshare/blob/60e19f96d540e2b3fb1c28a68ef61d9fb8eb1897/LICENSE) | Portable source/target declarations, tracked-repository metadata, selective deployment, dirty-tree handling, and explicit one-way transformation contracts. Its merge mode is not a content-conflict algorithm. | No. |
| [Vercel Skills](https://github.com/vercel-labs/skills) | [`80feb48868972d518436f26711509bc78595b5cb`](https://github.com/vercel-labs/skills/tree/80feb48868972d518436f26711509bc78595b5cb) | [MIT](https://github.com/vercel-labs/skills/blob/80feb48868972d518436f26711509bc78595b5cb/LICENSE) | Versioned global/project lock formats, agent/scope mapping, and batched repository checks. Implement compatible readers and grouped fetching; do not delegate review to its overwrite-oriented update flow. | No. |
| [AI Config Sync Manager](https://github.com/slash9494/ai-config-sync-manager) | [`493958615cda2ef3eda0ce4642ed96b505630fbe`](https://github.com/slash9494/ai-config-sync-manager/tree/493958615cda2ef3eda0ce4642ed96b505630fbe) | [MIT](https://github.com/slash9494/ai-config-sync-manager/blob/493958615cda2ef3eda0ce4642ed96b505630fbe/LICENSE) | Dated compatibility and unsupported-field register, upstream schema checks, and explicit transformation limits. Do not inherit broad secret copying or treat lossy mappings as equivalent behavior. | No. |
| [Agent Plugins](https://agent-plugins.org/) | Versioned portable contract: [plugin schema 1.0.0](https://agent-plugins.org/schemas/1.0.0/plugin.schema.json), [specification](https://agent-plugins.org/specification), and [loading contract](https://agent-plugins.org/client-implementers/loading-and-discovery). | Loading/discovery documentation identifies CC BY 4.0, inspected September 8, 2026. A separate pinned schema-file license remains unverified; no schema file is vendored by this batch. | Implement the published package schema and loader rules locally for supported components. It does not supply workspace ownership, assignment, synchronization, or universal client compatibility. | No third-party implementation copied; the Swift manifest/MCP models are independent implementations of the published contract. |

## Installed dependency boundary

`apps/agent-tooling-macos/Package.resolved` pins [Yams](https://github.com/jpsim/Yams)
at version `6.2.2`, revision `a27b21e0c81c5bf42049b897a62aaf387e80f279`.
This is an installed Swift package dependency, not competitor-source reuse.
The resolved checkout's `LICENSE` was inspected during implementation and is
[MIT, copyright JP Simard](https://github.com/jpsim/Yams/blob/a27b21e0c81c5bf42049b897a62aaf387e80f279/LICENSE).
Retain its copyright and permission notice with distributed copies; packaging
notice verification remains a release check.

## Evidence boundary

The pinned revisions and license links above come from
[competitor-review-2026-09.md](competitor-review-2026-09.md#source-reuse-and-inspected-revisions).
The intended reuse boundaries come from
[implementation-plan-2026-09.md](implementation-plan-2026-09.md#what-to-reuse-from-each-project)
and its Agent Plugins section. Re-check the exact upstream file and license
before any source import.
