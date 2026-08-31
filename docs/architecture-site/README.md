# Agent Tooling Atlas

The single maintained product and architecture site for Agent Tooling. It
explains the local-first macOS application, Claude Code, Codex, and Gemini
targets, portable Agent Plugin packages, MCP servers, profiles, sync, and the
boundary between local configuration and hosted account state.

## Local development

```bash
npm install
npm run dev
```

## Validation

```bash
npm test
```

The guide is intentionally self-contained. It uses no persistent storage,
authentication, external data, runtime server, or runtime secrets. It is a
static Next.js export, which keeps the documentation supply chain smaller than
the former Cloudflare/vinext starter. The retired
`docs/current-tooling` starter was removed because it duplicated this app and
carried unused D1, Drizzle, and authentication scaffolding.
