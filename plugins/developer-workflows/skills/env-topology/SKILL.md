---
name: env-topology
description: Authoritative map of how env vars and secrets flow across Doppler, Supabase, Vercel, EAS, GitHub Actions, and local .env files for PUMPD (mobile, backend, CI), the IAWIS store, and agent-tooling MCPs. Use when deciding where to set or find a variable, when a variable is undefined at runtime or build time, when wiring CI or EAS environments, or before answering any question about secret or env-var placement.
---

# Environment & secrets topology

Evidence-based map (verified 2026-07-22 from the Doppler CLI, repo sources, CI
workflows, and EAS config — names only). Prefer re-verifying with the live
queries below over trusting memory. Never print or commit secret values; query
names only.

## Mental model

One sentence per surface — where truth lives:

| Surface | Source of truth |
|---|---|
| Mobile runtime (`EXPO_PUBLIC_*`) | Doppler `pumpd-mobile` + **EAS Environments** (build-time); local `.env` overrides in dev |
| Native/OTA CI builds | GitHub Actions secrets (names mirror Doppler `pumpd-ci/prd`) + `eas env:pull` |
| Backend local + CI | **Generated** local `.env` from `supabase status` (`scripts/init.ts`); CI uses the local stack, zero secrets |
| Backend remote (auth providers, AI, Sentry) | Doppler `pumpd-backend` |
| IAWIS store (`always-wet-store`) | **Vercel project env only — no Doppler** |
| agent-tooling MCPs | Doppler `agent-tooling/prd` via `doppler run --only-secrets` |

## Doppler inventory

8 projects. 4-config projects use `dev` / `dev_personal` (personal branch off
dev) / `stg` / `prd`; the rest are `prd`-only (`pumpd-website` swaps `stg` for
`preview`).

| Project | Role | Notable names |
|---|---|---|
| `pumpd-mobile` | Mobile app vars | `APP_VARIANT`, `EXPO_PUBLIC_SUPABASE_URL/KEY`, `EXPO_PUBLIC_SENTRY_DSN`, `SENTRY_AUTH_TOKEN`, `EXPO_PUBLIC_REVENUECAT_API_KEY`+`EXPO_PUBLIC_GOOGLE_*` (provisioned, not yet consumed); `dev` adds `EXPO_PUBLIC_LOCAL_SUPABASE_URL/KEY` |
| `pumpd-backend` | Edge/runtime + remote Supabase auth | `SUPABASE_AUTH_{APPLE,FACEBOOK,GOOGLE}_*`, `SUPABASE_AUTH_SMS_TWILIO_VERIFY_AUTH_TOKEN`, `SUPABASE_SECRET_KEY`, `SUPABASE_URL`, `AI_PROVIDER/MODEL`, `GOOGLE_GENERATIVE_AI_API_KEY`, `GITHUB_BUG_REPORT_*`; `prd` has `SENTRY_*` that `dev` lacks; `dev` has `SUPABASE_PUBLISHABLE_KEY` that `prd` lacks |
| `pumpd-ci` | **The CI/CD secret bucket** | `EXPO_TOKEN`, `MATCH_*`, `PUMPD_MATCH_CERTS_CI_PAT`, `ASC_*`, `SENTRY_AUTH_TOKEN`, `SUPABASE_ACCESS_TOKEN`, `SUPABASE_PROJECT_ID_PRODUCTION`, `VERCEL_{TOKEN,ORG_ID,PROJECT_ID}`, `GH_PAT`, `FEEDBACK_AUTOMATION_*`, `HEROUI_AUTH_TOKEN` |
| `agent-tooling` | MCP tokens for this repo | `HEROUI_PRO_PERSONAL_TOKEN`, `GOOGLE_APPLICATION_CREDENTIALS`, `GOOGLE_PROJECT_ID` |
| `pumpd-website` | HeroUI marketing site | `NEXT_PUBLIC_SITE_URL`, `HEROUI_AUTH_TOKEN`; `preview` adds `NEXT_PUBLIC_SUPABASE_URL`, `SUPABASE_SECRET_KEY` |
| `pumpd-keymat` | dotenvx decrypt keys | `DOTENV_PRIVATE_KEY_{PREVIEW,PRODUCTION}` (consuming repo unresolved) |
| `pumpd-admin` / `pumpd-docs` | Near-empty | one `NEXT_PUBLIC_SUPABASE_URL` / none |

## Proven flow edges

1. **Doppler `pumpd-ci/prd` → GitHub Actions secrets → EAS/Fastlane.** Workflow
   `secrets.*` names match `pumpd-ci/prd` 1:1 (sync mechanism unconfirmed — see
   Unresolved).
2. **`APP_VARIANT` → app identity.** Set per `eas.json` profile (`dev` /
   `staging`); `app.config.ts` derives name, scheme, bundle id
   (`com.avadworkout.pumpdmobileapp[.dev]`), app group, and update channel.
3. **EAS Environments → build-time `EXPO_PUBLIC_*`.** CI runs
   `eas env:pull --environment $EAS_ENVIRONMENT` then re-exports only
   `EXPO_PUBLIC_*` lines. Mapping: `APP_VARIANT=dev` → `development`,
   `APP_VARIANT=staging` → `preview`. Build-time public vars come from **EAS
   Environments, not Doppler directly**.
4. **EAS channels ↔ update branches.** `eas.json` channels
   `development/staging/preview/production`; CI publishes `eas update --branch
   staging` and per-PR `--branch pr-<n>`.
5. **Mobile local-Supabase toggle.** `EXPO_PUBLIC_USE_LOCAL_SUPABASE=true`
   (the `start:local` script) swaps `EXPO_PUBLIC_LOCAL_SUPABASE_URL/KEY` in for
   the remote pair in `src/services/api/supabase-client.ts`.
6. **Type generation targets remote prod** — `types:gen` hardcodes project id
   `likkyekzftelrfindaes`; `types:gen:local` targets `localhost:54322`.
7. **Backend `.env` is a generated artifact.** `scripts/init.ts` writes
   `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY` from
   `supabase status`. Never hand-edit; re-run init instead. Edge functions read
   only `SUPABASE_URL` + `SUPABASE_ANON_KEY` (runtime-injected).
8. **IAWIS is Vercel-only.** Project `always-wet-store`; secrets in Vercel env,
   pulled locally via `vercel env pull`. Shopify/Resend/Judge.me/Instagram
   tokens live there — not in Doppler.
9. **agent-tooling MCPs** wrap servers with
   `doppler run --project agent-tooling --config prd --only-secrets <NAME>
   --no-fallback` (heroui-pro ×2, analytics-mcp).

## Decision table — set X for surface Y

| Need | Set it here |
|---|---|
| Mobile remote Supabase URL/key | Doppler `pumpd-mobile` (`EXPO_PUBLIC_SUPABASE_URL`, `EXPO_PUBLIC_SUPABASE_KEY`) **and** the matching EAS Environment |
| Mobile local Supabase | local `.env` (`EXPO_PUBLIC_USE_LOCAL_SUPABASE`, `EXPO_PUBLIC_LOCAL_SUPABASE_URL/KEY`); flip with `start:local` |
| Mobile Sentry DSN / source maps | Doppler `pumpd-mobile` (`EXPO_PUBLIC_SENTRY_DSN`, `SENTRY_AUTH_TOKEN`); DSN intentionally absent in local dev |
| New build-time `EXPO_PUBLIC_*` | EAS Environment (`development`/`preview`/`production`) + Doppler `pumpd-mobile` for the record |
| iOS signing / ASC / Expo token / Vercel deploy / Supabase deploy (CI) | Doppler `pumpd-ci/prd` → mirrored GitHub Actions secret |
| Backend remote auth providers, AI keys, bug-report | Doppler `pumpd-backend` (push path to remote Supabase unresolved) |
| Backend local stack keys | never set by hand — run the backend `init` script |
| IAWIS store secrets | Vercel env for project `always-wet-store` |
| MCP tokens for this repo | Doppler `agent-tooling/prd`, consumed via `doppler run --only-secrets` |

## Why is X undefined?

| Symptom | Check |
|---|---|
| `EXPO_PUBLIC_*` undefined at runtime (device/sim) | Was Metro started with the var present? Local: is it in `.env` / did you need `start:local`? Build: is it in the EAS Environment the profile maps to? |
| `EXPO_PUBLIC_*` undefined in CI native build | Only `EXPO_PUBLIC_*` lines survive the `eas env:pull` re-export; check the EAS Environment for `$EAS_ENVIRONMENT`, not Doppler |
| App has wrong bundle id / channel | `APP_VARIANT` not set (eas.json profile vs local shell) |
| Runtime points at wrong Supabase | `EXPO_PUBLIC_USE_LOCAL_SUPABASE` state + which URL pair is populated |
| Backend function missing a var locally | `.env` regenerated? (`init` script) Local stack running? |
| CI job missing a secret | GitHub environment (`dev` vs `staging`) + does the name exist in Doppler `pumpd-ci/prd`? |
| IAWIS var undefined | `vercel env pull` freshness; Vercel project env for `always-wet-store` |

## Live queries (names only — never print values)

```bash
doppler projects --json
doppler configs --project pumpd-mobile --json
doppler secrets --only-names --project pumpd-ci --config prd
eas env:list --environment preview          # from pumpd-mobile-app/
vercel env ls                               # from always-wet-store/
gh secret list                              # per repo; also: gh api repos/{owner}/{repo}/environments
```

## Known gotchas & unresolved (do not guess — ask or verify)

- **Stale example file:** mobile `.env.example` says `EXPO_PUBLIC_SUPABASE_ANON_KEY`;
  every real surface uses `EXPO_PUBLIC_SUPABASE_KEY`. Trust code + Doppler, not
  the example.
- `EXPO_PUBLIC_SECURE_STORAGE_KEY` is consumed in `src` but exists only in local
  `.env` — no Doppler/EAS home. UNRESOLVED how release builds obtain it.
- How Doppler `pumpd-backend` `SUPABASE_AUTH_*` reach the remote Supabase
  project is UNRESOLVED (`config.toml` hardcodes Apple client id + placeholder
  secret; no `env()` substitution).
- Doppler→GitHub and Doppler→EAS sync vs manual mirroring: UNRESOLVED (names
  match 1:1 but no sync config is visible in-repo).
- `pumpd-website` (Doppler) vs IAWIS `always-wet-store` (Vercel-only) are
  distinct surfaces; which Vercel project `pumpd-ci`'s `VERCEL_*` deploy is
  UNRESOLVED.
- `pumpd-keymat` dotenvx keys: consuming repo UNRESOLVED.
- Provisioned-but-unwired (expected): `EXPO_PUBLIC_REVENUECAT_API_KEY`,
  `EXPO_PUBLIC_GOOGLE_*` client ids sit in Doppler `pumpd-mobile` with no
  consumers yet.
