# analytics-mcp Authentication & Re-auth

This skill calls Google's official `analytics-mcp` server (https://github.com/googleanalytics/google-analytics-mcp) to pull GA4 data. The server authenticates to Google Analytics via Application Default Credentials (ADC). Those credentials expire periodically, and re-authenticating has burned hours on this setup before, because the README's gcloud command uses two non-obvious flags that are easy to drop. The notes below exist so the next re-auth takes one minute instead of an afternoon.

## The re-auth command

```bash
gcloud auth application-default login \
  --scopes=https://www.googleapis.com/auth/analytics.readonly,https://www.googleapis.com/auth/cloud-platform \
  --client-id-file="$IAWIS_GCLOUD_CLIENT_ID_FILE"
```

Sign in as `aren@wetinseattle.com` in the browser flow.

After it prints `Credentials saved to file: [PATH]`:
1. In Claude Code, run `/mcp` → reconnect `analytics-mcp`. The MCP server caches credentials at startup and won't pick up new ones until it reconnects.
2. Re-run the failed query — should now succeed.

## Why each flag matters

- **`--scopes=...analytics.readonly,...cloud-platform`** — without this, gcloud only grants the default `cloud-platform` scope, which is insufficient for the Analytics Data API. Every `run_report` call comes back with `403 ACCESS_TOKEN_SCOPE_INSUFFICIENT`.
- **`--client-id-file="$IAWIS_GCLOUD_CLIENT_ID_FILE"`** — without this, gcloud uses its default ADC OAuth client. The `wetinseattle.com` Workspace may block that generic client from accessing sensitive scopes. Pointing at the OAuth client created in the `iawis-analytics` GCP project uses the intended first-party client.

## Error → cause cheat sheet

| Symptom | Cause | Fix |
|---|---|---|
| `503 ... Reauthentication is needed. Please run gcloud auth application-default login` | Access token expired | Re-run the command above |
| `403 ACCESS_TOKEN_SCOPE_INSUFFICIENT` | Re-authed but without `--scopes=...analytics.readonly...` | Re-run *with* the scopes flag |
| Browser shows **"This app is blocked"** | Re-authed without `--client-id-file=` → fell back to generic gcloud client → Workspace blocked it | Re-run *with* the `--client-id-file=` flag |
| Tool calls fail right after a successful re-auth | MCP server still holds stale creds in memory | `/mcp` → reconnect `analytics-mcp` |

## IAWIS-specific values

| Thing | Value |
|---|---|
| Google account | `aren@wetinseattle.com` (Workspace) |
| GCP project | `iawis-analytics` |
| GA4 property ID | `509725408` |
| OAuth client JSON | `$IAWIS_GCLOUD_CLIENT_ID_FILE` |
| ADC credentials file (written by gcloud login) | `~/.config/gcloud/application_default_credentials.json` |

## If the OAuth client JSON is lost or moved

Re-download from GCP Console:
1. https://console.cloud.google.com/apis/credentials — confirm the project selector (top-left) is set to `iawis-analytics`.
2. APIs & Services → **Credentials**.
3. Under "OAuth 2.0 Client IDs" — find the existing Desktop-app client (likely named `analytics-mcp` or similar).
4. Click the ↓ download icon on its row → save the JSON.
5. Save it in a private local location and set `IAWIS_GCLOUD_CLIENT_ID_FILE` to that absolute path.

If the OAuth client itself was deleted (not just the local file):
1. Same Credentials page → **Create Credentials** → **OAuth client ID**.
2. Application type: **Desktop app**. (Name doesn't matter.)
3. Create → download the JSON.

Required APIs on the `iawis-analytics` project (should already be enabled — only check Library if you see an API-disabled error):
- Google Analytics Admin API
- Google Analytics Data API

## What NOT to do

- **Don't run plain `gcloud auth application-default login`** without both flags. It will appear to succeed, then every subsequent API call will fail with a scope or app-blocked error. This is the trap that ate hours of debugging before this doc existed.
- **Don't omit the `/mcp` reconnect** after re-authing. The MCP server holds the old credentials in memory and won't see the new ones until reconnect.
- **Don't try to "fix" the Workspace admin policy** to allow the generic gcloud client. The custom OAuth client approach is cleaner, already set up, and avoids touching org-wide settings.

## Reference

Setup originally followed: https://github.com/googleanalytics/google-analytics-mcp
