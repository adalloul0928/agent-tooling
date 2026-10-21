# Agent Tooling product guide

A static Next.js site describing the public macOS app. It has no backend,
authentication, analytics, or runtime data dependencies. System fonts keep the
build independent of a font service.

## Development

Requires Node.js 22.13 or later.

```sh
npm ci
npm run dev
```

## Validate and export

```sh
npm audit --audit-level=high
npm test
npm run lint
```

`npm test` builds the static export in `out/` and checks its rendered content.
`npm start` serves that export locally on port 3000.

The [Next ESLint compatibility package](tools/next-root-dir-glob/README.md)
replaces a vulnerable transitive glob dependency while preserving Next's lint
rules.
