---
name: cyrus-setup
description: Set up or repair self-hosted Cyrus end-to-end, including prerequisites, Claude authentication, webhook exposure, integrations, repository registration, and launch. Use for a new Cyrus installation or when one setup stage is incomplete.
---

# Cyrus Setup

Set up Cyrus as a background Claude Code agent for one or more supported work surfaces. Treat each stage as independently resumable: inspect first, skip what is already healthy, and never replace valid credentials just to make the setup uniform.

## Safety rules

- Never read secret-bearing files into chat or tool output. In particular, do not print the contents of Cyrus environment files, OAuth client secrets, webhook secrets, or tokens.
- Prefer official Cyrus documentation and the installed version's help output over remembered flags. Cyrus changes quickly.
- Use the active client's signed-in browser capability when available. Otherwise provide a guided manual flow; do not ask the user to paste secrets into chat.
- Do not create integrations or external apps until the user confirms the surfaces and names.
- Do not launch a second Cyrus process when one is already running.

## Inputs

Collect only the choices that affect setup:

- agent name and short description
- desired surfaces: Linear, GitHub, GitLab, Slack
- package manager
- repository checkout(s) to register
- preferred process manager or launch method

Use a structured question tool when available. At least one surface is required.

## Workflow

### 1. Inspect and verify prerequisites

1. Read the current Cyrus installation documentation and the local package/version metadata.
2. Verify the required runtime, package manager, Git, GitHub or GitLab CLI as applicable, and a supported Claude Code installation.
3. Check whether Cyrus is already installed and whether a process is already running.
4. Install only missing prerequisites, using the user's selected package manager.

Report versions without printing environment values.

### 2. Configure Claude authentication

Follow the authentication method supported by the installed Cyrus and Claude Code versions. Prefer an interactive login or a secret-manager-backed environment reference. Pause for the user when a browser or terminal login requires human action. Verify authentication with a non-secret status command; never echo tokens.

### 3. Expose the webhook endpoint

Choose the supported endpoint mechanism for the user's environment, such as the configured deployment, reverse proxy, or development tunnel. Record only the public callback URL and non-secret settings. Confirm the endpoint responds before creating external integrations.

### 4. Create selected integrations

For each selected surface:

1. Open the official app/integration creation page using an existing signed-in browser session when available.
2. Prefer manifest-based app creation when the provider supports it.
3. Configure the minimum scopes and event subscriptions documented by Cyrus.
4. Write returned secrets directly to the approved local secret store or environment file without reading them back into the conversation.
5. Verify the integration using Cyrus's status or connection check.

Skip unselected surfaces. If a provider requires organization-admin approval, stop at that boundary and provide the exact approval action.

### 5. Register repositories

For each requested repository:

1. Confirm the checkout and default integration branch.
2. Read its agent instructions and project configuration.
3. Register the repository using the installed Cyrus CLI or configuration schema.
4. Keep repo-specific instructions in the repository; do not copy them into global Cyrus configuration.
5. Verify Cyrus can inspect the repository without mutating it.

### 6. Launch and verify

1. Start Cyrus with the user's chosen process manager.
2. Verify one healthy process, the webhook health endpoint, and each selected integration's connection state.
3. Run a read-only or disposable smoke task only if the user authorizes testing.
4. Report the process name, log command, callback URL, registered repositories, and any manual follow-up.

## Re-run behavior

On later runs, begin with an inventory and offer only incomplete or unhealthy stages. Never rotate working credentials, recreate apps, or duplicate repository registrations without a specific reason and user approval.

## Finish

Summarize:

- Cyrus and Claude Code versions
- enabled integrations
- registered repositories
- process/health status
- deferred authentication or admin approvals
- the exact command for viewing logs
