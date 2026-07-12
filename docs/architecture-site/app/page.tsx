"use client";

import { useState } from "react";

type Status = "automatic" | "native" | "manual" | "pilot";

type Journey = {
  id: string;
  eyebrow: string;
  title: string;
  summary: string;
  rule: string;
  steps: Array<{
    index: string;
    title: string;
    detail: string;
    status: Status;
    owner: string;
  }>;
};

const journeys: Journey[] = [
  {
    id: "owned-skill",
    eyebrow: "You wrote it",
    title: "Owned skill",
    summary:
      "A portable SKILL.md lives once in agent-tooling, then thin adapters expose it to each client without duplicating its workflow.",
    rule: "One physical skill core. Multiple native delivery paths.",
    steps: [
      {
        index: "01",
        title: "Author once",
        detail:
          "Add the skill, scripts, references, and assets under agent-tooling. Keep instructions capability-based and paths package-relative.",
        status: "automatic",
        owner: "agent-tooling",
      },
      {
        index: "02",
        title: "Package and lock",
        detail:
          "APM resolves the package, records an exact source and content hash, and can generate the Claude and Codex catalogs.",
        status: "pilot",
        owner: "APM",
      },
      {
        index: "03",
        title: "Install locally",
        detail:
          "APM renders the shared skill into Claude Code and Codex native locations. Each client still reads its own files.",
        status: "automatic",
        owner: "APM → clients",
      },
      {
        index: "04",
        title: "Publish to hosted Claude",
        detail:
          "The same Claude catalog can back a personal account marketplace, but installation and refresh are account-side actions.",
        status: "manual",
        owner: "Claude account",
      },
      {
        index: "05",
        title: "Commit if cloud-critical",
        detail:
          "If a cloud coding task must have the skill, commit a project projection in the application repository and test it there.",
        status: "native",
        owner: "project repo",
      },
    ],
  },
  {
    id: "vendor-plugin",
    eyebrow: "Someone else owns it",
    title: "Vendor plugin",
    summary:
      "Linear, Supabase, Sentry, and other vendor plugins stay in their vendor marketplace. Your repo records intent; it does not redistribute them.",
    rule: "Reference vendor tooling. Never fork it into your private catalog just for convenience.",
    steps: [
      {
        index: "01",
        title: "Record the capability",
        detail:
          "Declare that the workstation or project expects a capability such as Linear, including which surfaces should receive it.",
        status: "pilot",
        owner: "APM profile",
      },
      {
        index: "02",
        title: "Install natively",
        detail:
          "Use Claude's or Codex's own marketplace so scopes, dependencies, updates, and enablement retain vendor-native behavior.",
        status: "native",
        owner: "vendor marketplace",
      },
      {
        index: "03",
        title: "Authenticate per client",
        detail:
          "OAuth and tokens remain in the client or account that uses them. Credentials never belong in agent-tooling or an APM lockfile.",
        status: "manual",
        owner: "local client",
      },
      {
        index: "04",
        title: "Verify hosted separately",
        detail:
          "A hosted Claude or ChatGPT plugin is a separate installation store even when it represents the same business capability.",
        status: "manual",
        owner: "hosted account",
      },
    ],
  },
  {
    id: "mcp",
    eyebrow: "A tool connection",
    title: "MCP server",
    summary:
      "One neutral desired-state entry can produce Claude JSON and Codex TOML, while client-specific overrides preserve real differences.",
    rule: "Share intent, not secrets. Render native files instead of forcing identical schemas.",
    steps: [
      {
        index: "01",
        title: "Declare once",
        detail:
          "Put command, arguments, transport, environment placeholders, scope, and target clients in the APM manifest.",
        status: "pilot",
        owner: "APM manifest",
      },
      {
        index: "02",
        title: "Render per client",
        detail:
          "APM writes Claude's MCP JSON and Codex's MCP TOML without pretending the two schemas are identical.",
        status: "automatic",
        owner: "APM adapters",
      },
      {
        index: "03",
        title: "Authorize locally",
        detail:
          "Environment values, OAuth, and approval prompts stay in each runtime. The manifest contains references, never live credentials.",
        status: "manual",
        owner: "runtime auth",
      },
      {
        index: "04",
        title: "Commit project MCPs",
        detail:
          "Cloud-required servers live in the project as .mcp.json and .codex/config.toml outputs, with cloud-safe auth and networking.",
        status: "native",
        owner: "project repo",
      },
      {
        index: "05",
        title: "Audit and prune",
        detail:
          "APM can compare declared state with deployed files, report drift, and remove only resources it owns.",
        status: "pilot",
        owner: "APM lifecycle",
      },
    ],
  },
  {
    id: "project-behavior",
    eyebrow: "The project depends on it",
    title: "Project-critical behavior",
    summary:
      "Instructions and skills required by PUMPD cloud work belong in the PUMPD repository, even when their reusable source began elsewhere.",
    rule: "The cloud trusts the checkout. Put required behavior in the checkout.",
    steps: [
      {
        index: "01",
        title: "Define the shared core",
        detail:
          "Keep universal project rules in AGENTS.md and reusable procedures as focused skills rather than growing one giant instruction file.",
        status: "native",
        owner: "project repo",
      },
      {
        index: "02",
        title: "Project install",
        detail:
          "An APM project manifest can resolve shared packages and produce Claude and Codex project-native outputs.",
        status: "pilot",
        owner: "project APM",
      },
      {
        index: "03",
        title: "Commit generated outputs",
        detail:
          "Commit CLAUDE.md/.claude and AGENTS.md/.agents/.codex artifacts that the cloud clients actually receive.",
        status: "automatic",
        owner: "Git",
      },
      {
        index: "04",
        title: "Run cloud canaries",
        detail:
          "Claude cloud has a documented project configuration matrix. Codex cloud behavior beyond AGENTS.md remains more conservative and must be tested.",
        status: "pilot",
        owner: "cloud sessions",
      },
    ],
  },
  {
    id: "hosted-connector",
    eyebrow: "Lives in an account",
    title: "Hosted connector",
    summary:
      "Gmail, Drive, Linear, and other account connectors are account-side capabilities. Git can document them but cannot own their installation or OAuth state.",
    rule: "Hosted state is verified, not synchronized.",
    steps: [
      {
        index: "01",
        title: "Connect in the account",
        detail:
          "Install the connector in Claude or ChatGPT and complete its native authorization flow.",
        status: "manual",
        owner: "hosted account",
      },
      {
        index: "02",
        title: "Choose its surfaces",
        detail:
          "Enable the connector only where it is useful. Claude Code local can be separated from Claude.ai connectors for a predictable inventory.",
        status: "manual",
        owner: "account settings",
      },
      {
        index: "03",
        title: "Record expected state",
        detail:
          "The tooling profile records the intended connector, surface, and last-verified date without storing credentials.",
        status: "pilot",
        owner: "account checklist",
      },
      {
        index: "04",
        title: "Use a local twin if needed",
        detail:
          "When local Code needs the same capability, install a deliberate local plugin, CLI, or MCP twin rather than relying on invisible inheritance.",
        status: "native",
        owner: "local client",
      },
    ],
  },
];

const surfaces = [
  {
    family: "Claude",
    tone: "claude",
    items: [
      {
        name: "Chat + Desktop Chat",
        kind: "Hosted account",
        receives: "Account skills, connectors, installed account plugins",
        misses: "Local ~/.claude and project machine state",
      },
      {
        name: "Cowork",
        kind: "Hosted workbench",
        receives: "Account plugins, connectors, skills, hooks, sub-agents",
        misses: "Private machine paths unless explicitly exposed",
      },
      {
        name: "Code Desktop + CLI",
        kind: "Local code client",
        receives: "CLAUDE.md, ~/.claude, repo .claude, MCPs, Code plugins",
        misses: "Codex configuration; account connectors after separation",
      },
      {
        name: "Code cloud + Routines",
        kind: "Fresh cloud VM",
        receives: "Cloned repo config, project plugins/MCPs, enabled account skills",
        misses: "Local home skills, user plugins, local MCP state",
      },
    ],
  },
  {
    family: "Codex",
    tone: "codex",
    items: [
      {
        name: "ChatGPT Work",
        kind: "Hosted account",
        receives: "Installed hosted plugins, apps, connectors",
        misses: "Local ~/.codex configuration",
      },
      {
        name: "App + CLI + IDE",
        kind: "Local code client",
        receives: "AGENTS.md, skills, ~/.codex config, installed Codex plugins",
        misses: "Claude configuration and Claude account state",
      },
      {
        name: "Codex cloud",
        kind: "Cloud checkout",
        receives: "Selected repo revision, AGENTS.md, committed files, environment",
        misses: "Local marketplaces and home config unless provisioned",
      },
      {
        name: "Import",
        kind: "One-time migration",
        receives: "A copied snapshot of selected Claude setup",
        misses: "Ongoing synchronization after import",
      },
    ],
  },
];

const matrixRows = [
  ["Owned skill", "Canonical source", "Install + lock", "Plugin install", "Account plugin", "Commit projection", "Plugin install", "Commit + canary"],
  ["Vendor plugin", "Reference only", "Pilot tracking", "Native marketplace", "Native marketplace", "Project declaration", "Native marketplace", "Pilot"],
  ["MCP server", "Definition/template", "Render adapters", "JSON config", "Connector UI", "Committed .mcp.json", "TOML config", "Committed config"],
  ["Project rules", "Reusable pieces", "Project render", "CLAUDE.md", "Not inherited", "Repo checkout", "AGENTS.md", "Repo checkout"],
  ["OAuth / secrets", "Never", "References only", "Local runtime", "Account", "Cloud environment", "Local runtime", "Cloud environment"],
];

const statusLabels: Record<Status, string> = {
  automatic: "Automated path",
  native: "Native client path",
  manual: "Human/account action",
  pilot: "Pilot before relying",
};

function StatusPill({ status }: { status: Status }) {
  return <span className={`status status-${status}`}>{statusLabels[status]}</span>;
}

export default function Home() {
  const [activeJourney, setActiveJourney] = useState(journeys[0].id);
  const journey = journeys.find((item) => item.id === activeJourney) ?? journeys[0];

  return (
    <main>
      <header className="topbar">
        <a className="brand" href="#top" aria-label="Agent Tooling Atlas home">
          <span className="brand-mark">AT</span>
          <span>Agent Tooling Atlas</span>
        </a>
        <nav aria-label="Guide sections">
          <a href="#model">Model</a>
          <a href="#surfaces">Surfaces</a>
          <a href="#journeys">Trace a capability</a>
          <a href="#operations">Operations</a>
        </nav>
        <span className="pilot-badge">Pilot architecture · 2026.07</span>
      </header>

      <section className="hero" id="top">
        <div className="hero-grid" aria-hidden="true" />
        <div className="hero-copy">
          <p className="kicker">A field guide to the whole system</p>
          <h1>
            One source.
            <br />
            <em>Many surfaces.</em>
          </h1>
          <p className="hero-intro">
            A visual map of what <strong>agent-tooling</strong> owns, what <strong>APM</strong> can automate,
            what Claude and Codex load locally or in the cloud, and where a human still has to click, connect, or verify.
          </p>
          <div className="hero-actions">
            <a className="button button-primary" href="#model">Start with the model <span>↓</span></a>
            <a className="button button-ghost" href="#journeys">Trace something I add</a>
          </div>
        </div>

        <div className="hero-diagram" aria-label="Source to surfaces overview">
          <div className="diagram-note note-top">Git is truth for content</div>
          <div className="orbit orbit-one" />
          <div className="orbit orbit-two" />
          <div className="core-node">
            <span className="node-index">01</span>
            <strong>agent-tooling</strong>
            <small>owned source + catalogs</small>
          </div>
          <div className="satellite satellite-apm">
            <span>02</span><strong>APM</strong><small>desired state</small>
          </div>
          <div className="satellite satellite-claude">
            <span>03A</span><strong>Claude</strong><small>native adapter</small>
          </div>
          <div className="satellite satellite-codex">
            <span>03B</span><strong>Codex</strong><small>native adapter</small>
          </div>
          <div className="satellite satellite-account">
            <span>04</span><strong>Accounts</strong><small>manual state</small>
          </div>
          <div className="diagram-note note-bottom">Cloud trusts the project checkout</div>
        </div>
      </section>

      <section className="plain-language band">
        <span className="section-number">00</span>
        <div>
          <p className="kicker">The plain-English version</p>
          <h2>Git stores the recipe. APM prepares the kitchens. Each app still cooks in its own way.</h2>
        </div>
        <p>
          Nothing turns Claude and Codex into one product. The strategy gives them a shared source where possible,
          native configuration where necessary, and an explicit checklist where automation stops.
        </p>
      </section>

      <section className="section model-section" id="model">
        <div className="section-heading">
          <div>
            <p className="kicker">01 · The operating model</p>
            <h2>Four layers, four different jobs</h2>
          </div>
          <p className="section-lede">
            Most confusion comes from asking one layer to do another layer&apos;s job. A catalog is not an installation.
            A local installation is not cloud configuration. A Git push is not account OAuth.
          </p>
        </div>

        <div className="layer-grid">
          <article className="layer-card layer-source">
            <div className="layer-topline"><span>Layer 01</span><span>Own</span></div>
            <h3>agent-tooling</h3>
            <p>Your private, durable source for tooling you own.</p>
            <ul>
              <li>Portable skill cores</li>
              <li>Claude + Codex plugin adapters</li>
              <li>Native marketplace catalogs</li>
              <li>Scripts, references, assets</li>
            </ul>
            <div className="layer-rule">Does not store secrets or account state.</div>
          </article>

          <article className="layer-card layer-apm">
            <div className="layer-topline"><span>Layer 02</span><span>Reconcile</span></div>
            <h3>Microsoft APM</h3>
            <p>The candidate package manager for local and project desired state.</p>
            <ul>
              <li>One manifest + exact lockfile</li>
              <li>Target-specific rendering</li>
              <li>Install, update, audit, prune</li>
              <li>Catalog generation + CI checks</li>
            </ul>
            <div className="layer-rule">Pilot first. It is not yet the trusted production owner.</div>
          </article>

          <article className="layer-card layer-native">
            <div className="layer-topline"><span>Layer 03</span><span>Run</span></div>
            <h3>Native clients</h3>
            <p>Claude and Codex consume their own formats and retain their own behavior.</p>
            <ul>
              <li>Claude JSON + .claude directories</li>
              <li>Codex TOML + .agents directories</li>
              <li>Vendor marketplaces stay native</li>
              <li>Local auth stays local</li>
            </ul>
            <div className="layer-rule">Share intent; preserve client-specific semantics.</div>
          </article>

          <article className="layer-card layer-hosted">
            <div className="layer-topline"><span>Layer 04</span><span>Verify</span></div>
            <h3>Hosted accounts</h3>
            <p>Claude.ai and ChatGPT stores remain separate, human-managed surfaces.</p>
            <ul>
              <li>Account plugins + skills</li>
              <li>Connectors and OAuth</li>
              <li>Manual installation and refresh</li>
              <li>Last-verified state ledger</li>
            </ul>
            <div className="layer-rule">Expected state is recorded, never falsely reported as synced.</div>
          </article>
        </div>

        <div className="truth-strip">
          <div><span>Source of truth</span><strong>agent-tooling + project Git</strong></div>
          <div><span>Desired state</span><strong>APM manifests + lockfiles</strong></div>
          <div><span>Actual state</span><strong>Native clients + account UIs</strong></div>
          <div><span>Proof</span><strong>doctor, audit, and canaries</strong></div>
        </div>
      </section>

      <section className="section surfaces-section" id="surfaces">
        <div className="section-heading">
          <div>
            <p className="kicker">02 · Surface map</p>
            <h2>Claude and Codex are families of products</h2>
          </div>
          <p className="section-lede">
            “It works in Claude” is incomplete. The real question is: which Claude, running where, and reading which store?
          </p>
        </div>

        <div className="surface-families">
          {surfaces.map((group) => (
            <div className={`surface-family ${group.tone}`} key={group.family}>
              <div className="family-heading">
                <span className="family-mark">{group.family.slice(0, 1)}</span>
                <div><p>Product family</p><h3>{group.family}</h3></div>
              </div>
              <div className="surface-list">
                {group.items.map((item, index) => (
                  <article className="surface-card" key={item.name}>
                    <div className="surface-title">
                      <span>{String(index + 1).padStart(2, "0")}</span>
                      <div><h4>{item.name}</h4><p>{item.kind}</p></div>
                    </div>
                    <dl>
                      <div><dt>Reliably receives</dt><dd>{item.receives}</dd></div>
                      <div><dt>Does not inherit</dt><dd>{item.misses}</dd></div>
                    </dl>
                  </article>
                ))}
              </div>
            </div>
          ))}
        </div>

        <div className="cloud-rule">
          <span className="cloud-rule-icon">↳</span>
          <div>
            <p className="kicker">The cloud reliability rule</p>
            <h3>If a cloud task must have it, commit it to the project and test it in that cloud.</h3>
          </div>
          <p>A private marketplace working on your laptop does not prove a fresh remote VM can authenticate to it.</p>
        </div>
      </section>

      <section className="section journey-section" id="journeys">
        <div className="section-heading journey-heading">
          <div>
            <p className="kicker">03 · Trace a capability</p>
            <h2>What happens when I add…?</h2>
          </div>
          <div className="legend" aria-label="Status legend">
            {(Object.keys(statusLabels) as Status[]).map((status) => <StatusPill status={status} key={status} />)}
          </div>
        </div>

        <div className="journey-tabs" role="tablist" aria-label="Capability type">
          {journeys.map((item) => (
            <button
              key={item.id}
              className={item.id === journey.id ? "active" : ""}
              onClick={() => setActiveJourney(item.id)}
              role="tab"
              aria-selected={item.id === journey.id}
              aria-controls="journey-panel"
            >
              <span>{item.eyebrow}</span>
              {item.title}
            </button>
          ))}
        </div>

        <div className="journey-panel" id="journey-panel" role="tabpanel">
          <div className="journey-summary">
            <p className="kicker">{journey.eyebrow}</p>
            <h3>{journey.title}</h3>
            <p>{journey.summary}</p>
            <blockquote>{journey.rule}</blockquote>
          </div>
          <div className="journey-steps">
            {journey.steps.map((step, index) => (
              <article className="journey-step" key={`${journey.id}-${step.index}`}>
                <div className="step-rail" aria-hidden="true">
                  <span>{step.index}</span>
                  {index < journey.steps.length - 1 && <i />}
                </div>
                <div className="step-content">
                  <div className="step-heading">
                    <div><p>{step.owner}</p><h4>{step.title}</h4></div>
                    <StatusPill status={step.status} />
                  </div>
                  <p>{step.detail}</p>
                </div>
              </article>
            ))}
          </div>
        </div>
      </section>

      <section className="section apm-section" id="operations">
        <div className="section-heading">
          <div>
            <p className="kicker">04 · APM&apos;s role</p>
            <h2>A package manager, not another agent</h2>
          </div>
          <p className="section-lede">
            APM runs before the clients. It prepares and verifies configuration; it does not answer prompts, hold OAuth, or replace Claude and Codex.
          </p>
        </div>

        <div className="lifecycle">
          {[
            ["01", "Declare", "apm.yml says what each target should receive"],
            ["02", "Resolve", "Sources and transitive dependencies are selected"],
            ["03", "Lock", "Exact commits and content hashes are recorded"],
            ["04", "Render", "Native Claude and Codex files are produced"],
            ["05", "Audit", "Missing, edited, or orphaned files are reported"],
            ["06", "Update", "A reviewed plan advances versions or removes state"],
          ].map(([number, title, copy], index) => (
            <article key={number}>
              <div className="life-number">{number}</div>
              <h3>{title}</h3>
              <p>{copy}</p>
              {index < 5 && <span className="life-arrow" aria-hidden="true">→</span>}
            </article>
          ))}
        </div>

        <div className="apm-split">
          <article className="apm-does">
            <p className="kicker">What APM can own</p>
            <h3>File-based, reproducible state</h3>
            <div className="check-grid">
              {[
                "Portable skill installation",
                "Claude/Codex target rendering",
                "MCP definitions and provenance",
                "Dependency and version locking",
                "Generated-file ownership",
                "Drift and integrity audits",
                "Safe uninstall and prune",
                "Marketplace artifact generation",
              ].map((item) => <div key={item}><span>+</span>{item}</div>)}
            </div>
          </article>
          <article className="apm-does-not">
            <p className="kicker">What remains outside APM</p>
            <h3>Identity, accounts, and runtime trust</h3>
            <div className="check-grid">
              {[
                "Claude.ai standalone skill state",
                "ChatGPT account plugin state",
                "Connector installation and OAuth",
                "Native vendor plugin guarantees",
                "Secret storage or token rotation",
                "Cloud network authorization",
                "MCP process sandboxing",
                "Proof that a workflow is effective",
              ].map((item) => <div key={item}><span>×</span>{item}</div>)}
            </div>
          </article>
        </div>

        <div className="command-card">
          <div className="command-copy">
            <p className="kicker">The eventual workstation loop</p>
            <h3>Change intent, preview, apply, prove.</h3>
            <p>Commands shown are the target operating model. APM remains behind a disposable-home pilot until its config-preservation canaries pass.</p>
          </div>
          <pre aria-label="Example APM workflow"><code><span className="prompt">$</span> apm install --dry-run
<span className="comment"># inspect the proposed Claude + Codex changes</span>

<span className="prompt">$</span> apm install -g --target claude,codex
<span className="comment"># reconcile the approved local state</span>

<span className="prompt">$</span> apm audit
<span className="comment"># prove deployed files match the lock</span>

<span className="prompt">$</span> apm update --dry-run
<span className="comment"># review updates before accepting them</span></code></pre>
        </div>
      </section>

      <section className="section matrix-section">
        <div className="section-heading">
          <div>
            <p className="kicker">05 · Ownership matrix</p>
            <h2>Who owns what?</h2>
          </div>
          <p className="section-lede">Read across any row to see the same capability expressed through different stores and runtimes.</p>
        </div>
        <div className="matrix-wrap" tabIndex={0} aria-label="Scrollable capability ownership matrix">
          <table>
            <thead>
              <tr>
                <th>Capability</th>
                <th>agent-tooling</th>
                <th>APM</th>
                <th>Claude local</th>
                <th>Claude hosted</th>
                <th>Claude cloud</th>
                <th>Codex local</th>
                <th>Codex cloud</th>
              </tr>
            </thead>
            <tbody>
              {matrixRows.map((row) => (
                <tr key={row[0]}>{row.map((cell, index) => index === 0 ? <th key={cell}>{cell}</th> : <td key={`${row[0]}-${cell}`}>{cell}</td>)}</tr>
              ))}
            </tbody>
          </table>
        </div>
      </section>

      <section className="section decision-section">
        <div className="decision-intro">
          <p className="kicker">06 · Placement rules</p>
          <h2>Five questions decide where a capability belongs</h2>
          <p>Use these before adding anything. They prevent duplicates, auth collisions, and accidental cloud dependencies.</p>
        </div>
        <ol className="decision-list">
          {[
            ["Do we own it?", "Yes: source it in agent-tooling. No: reference the vendor and keep its native installer."],
            ["Which surfaces need it?", "Name exact products: Claude Chat, Claude Code local, Claude cloud, Codex local, or Codex cloud."],
            ["Is it project-critical?", "If a cloud task cannot succeed without it, commit the required behavior to the project."],
            ["Does it need identity?", "OAuth, tokens, and connectors stay with the account or runtime that uses them."],
            ["How will we prove it arrived?", "Use native inventory, an update canary, and a last-verified date—not assumptions."],
          ].map(([question, answer], index) => (
            <li key={question}>
              <span>{String(index + 1).padStart(2, "0")}</span>
              <div><h3>{question}</h3><p>{answer}</p></div>
            </li>
          ))}
        </ol>
      </section>

      <section className="section end-state-section">
        <div className="end-state-card">
          <p className="kicker">The end state</p>
          <h2>You add intent once.<br />The system tells you what is automatic—and what is not.</h2>
          <div className="end-state-flow">
            <div><span>1</span><strong>Add or declare</strong><small>in the canonical source</small></div>
            <i>→</i>
            <div><span>2</span><strong>Preview and apply</strong><small>through APM or native manager</small></div>
            <i>→</i>
            <div><span>3</span><strong>Verify each surface</strong><small>with inventory and canaries</small></div>
            <i>→</i>
            <div><span>4</span><strong>Record manual state</strong><small>for accounts and OAuth</small></div>
          </div>
        </div>
      </section>

      <section className="section sources-section">
        <div>
          <p className="kicker">Source notes</p>
          <h2>Built from current product documentation</h2>
          <p>This atlas describes the target strategy, not proof that every pilot path is already live. Product behavior marked as pilot must be canaried before it becomes a dependency.</p>
        </div>
        <div className="source-links">
          <a href="https://code.claude.com/docs/en/claude-code-on-the-web" target="_blank" rel="noreferrer"><span>Anthropic</span>Claude Code cloud configuration ↗</a>
          <a href="https://code.claude.com/docs/en/plugin-marketplaces" target="_blank" rel="noreferrer"><span>Anthropic</span>Plugin marketplaces ↗</a>
          <a href="https://support.claude.com/en/articles/13837440-use-plugins-in-claude" target="_blank" rel="noreferrer"><span>Anthropic</span>Account plugins and surfaces ↗</a>
          <a href="https://learn.chatgpt.com/docs/plugins" target="_blank" rel="noreferrer"><span>OpenAI</span>Codex and ChatGPT plugins ↗</a>
          <a href="https://microsoft.github.io/apm/reference/targets-matrix/" target="_blank" rel="noreferrer"><span>Microsoft</span>APM target matrix ↗</a>
          <a href="https://microsoft.github.io/apm/reference/lockfile-spec/" target="_blank" rel="noreferrer"><span>Microsoft</span>APM lockfile and drift ↗</a>
          <a href="https://microsoft.github.io/apm/producer/publish-to-a-marketplace/" target="_blank" rel="noreferrer"><span>Microsoft</span>Dual marketplace publishing ↗</a>
        </div>
      </section>

      <footer>
        <div className="brand"><span className="brand-mark">AT</span><span>Agent Tooling Atlas</span></div>
        <p>One source where possible. Native adapters where necessary. Manual truth where automation ends.</p>
        <a href="#top">Back to top ↑</a>
      </footer>
    </main>
  );
}
