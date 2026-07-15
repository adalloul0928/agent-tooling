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
        title: "Package natively",
        detail:
          "Add thin Claude and Codex manifests plus entries in both native catalogs. Git revisions identify the release.",
        status: "native",
        owner: "agent-tooling",
      },
      {
        index: "03",
        title: "Install locally",
        detail:
          "Each client installs the matching native plugin from the same Git revision. Each still reads its own catalog and cache.",
        status: "automatic",
        owner: "native marketplaces",
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
        owner: "desired-state profile",
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
          "OAuth and tokens remain in the client or account that uses them. Credentials never belong in agent-tooling or a desired-state profile.",
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
      "Profiles record which MCP capability belongs on each surface, while Claude JSON and Codex TOML remain native, reviewable files.",
    rule: "Share intent, not secrets. Keep native schemas explicit instead of forcing identical configuration.",
    steps: [
      {
        index: "01",
        title: "Classify once",
        detail:
          "Record the capability owner, scope, target clients, and whether it is user-local or project-critical in the profile and docs.",
        status: "automatic",
        owner: "profile + docs",
      },
      {
        index: "02",
        title: "Configure per client",
        detail:
          "Write Claude's MCP JSON and Codex's MCP TOML through each native CLI or committed project file.",
        status: "native",
        owner: "native config",
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
          "The read-only doctor compares declared state with local files. Cleanup is explicit, backed up, and performed with native CLIs.",
        status: "automatic",
        owner: "doctor + native CLIs",
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
        title: "Project projection",
        detail:
          "Commit one canonical skill under .agents/skills and expose it to Claude with an in-repo relative directory symlink.",
        status: "native",
        owner: "project repo",
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
        name: "Claude.ai Chat",
        kind: "Hosted account",
        receives: "Enabled account skills, connectors, and account plugins",
        misses: "Local ~/.claude, local MCPs, and a project checkout",
      },
      {
        name: "Claude Desktop Chat",
        kind: "Desktop chat surface",
        receives: "Claude account state plus desktop chat extensions and MCP configuration",
        misses: "Claude Code plugin state merely because Code is embedded in the same app",
      },
      {
        name: "Code Desktop + CLI",
        kind: "Local code client",
        receives: "CLAUDE.md, local and project .claude config, Code plugins, local MCPs",
        misses: "Codex configuration; hosted connectors when user-scoped separation is enabled",
      },
      {
        name: "Code cloud + Routines",
        kind: "Fresh cloud VM",
        receives: "Committed repo config, project-declared plugins/MCPs, enabled claude.ai skills",
        misses: "Local home skills, user-only Code plugins, local MCP state, local credentials",
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
  ["Owned skill", "Canonical source", "Expected plugin", "Plugin install", "Account plugin", "Commit projection", "Plugin install", "Commit + canary"],
  ["Vendor plugin", "Reference only", "Expected vendor", "Native marketplace", "Native marketplace", "Project declaration", "Native marketplace", "Manual check"],
  ["MCP server", "Docs/template", "Expected server", "JSON config", "Connector UI", "Committed .mcp.json", "TOML config", "Committed config"],
  ["Project rules", "Reusable pieces", "Expected files", "CLAUDE.md", "Not inherited", "Repo checkout", "AGENTS.md", "Repo checkout"],
  ["OAuth / secrets", "Never", "Manual only", "Local runtime", "Account", "Cloud environment", "Local runtime", "Cloud environment"],
];

const buildingBlocks = [
  {
    name: "Skill",
    role: "Teaches a repeatable procedure",
    example: "obsidian-vault, pumpd-plan",
    boundary: "Instructions and supporting files; it does not grant service access by itself.",
  },
  {
    name: "MCP server",
    role: "Provides live tools or data",
    example: "analytics-mcp, Supabase",
    boundary: "A declaration is separate from authentication and runtime health.",
  },
  {
    name: "Plugin",
    role: "Bundles one or more atoms",
    example: "personal, cyrus-workflows",
    boundary: "May contain skills, MCP declarations, hooks, or agents; installation is client-specific.",
  },
  {
    name: "Marketplace",
    role: "Advertises installable plugins",
    example: "agent-tooling, openai-curated",
    boundary: "Registering a catalog does not install every plugin inside it.",
  },
  {
    name: "Connector / app",
    role: "Adds an account-hosted integration",
    example: "Gmail, Drive, hosted Linear",
    boundary: "Lives in Claude.ai or ChatGPT account state, outside local Git.",
  },
  {
    name: "CLI",
    role: "Executes a vendor's native commands",
    example: "supabase, doppler, expo, vercel",
    boundary: "Often complements an MCP; credentials remain in the vendor or local environment.",
  },
  {
    name: "Profile",
    role: "Describes expected state",
    example: "pumpd-workstation",
    boundary: "Our doctor reads and reports it; profiles never install or authenticate anything.",
  },
  {
    name: "Project config",
    role: "Guarantees checkout-owned behavior",
    example: "AGENTS.md, .mcp.json",
    boundary: "This is the reliable path for local teammates and fresh cloud sessions.",
  },
];

const ownedBundles = [
  {
    name: "personal",
    scope: "Base workstation",
    skills: ["obsidian-vault", "dad-daily-update", "personal-task", "personal-task-done"],
    note: "Installed in local Claude Code and Codex. This is the home for future broadly useful personal workflows.",
  },
  {
    name: "cyrus-workflows",
    scope: "PUMPD workstation",
    skills: ["cyrus-setup", "pumpd-research", "pumpd-plan", "pumpd-review", "pumpd-decompose", "log-learning", "pumpd-retro"],
    note: "Owns the Cyrus research-to-delegation loop. Learning and retro remain human-triggered for now.",
  },
  {
    name: "pumpd-workflows",
    scope: "PUMPD workstation",
    skills: ["pumpd-local-cleanup"],
    note: "Only local PUMPD maintenance that is not part of the Cyrus automation pipeline.",
  },
  {
    name: "wet-in-seattle",
    scope: "Wet In Seattle workstation",
    skills: ["iawis-weekly-report"],
    note: "Project-specific reporting workflow. The plugin supplies analytics-mcp to both clients and Doppler injects its allowlisted environment at startup.",
  },
  {
    name: "mobile-development",
    scope: "Base workstation",
    skills: ["ios-simulator-mcp", "heroui-native", "heroui-native-pro"],
    note: "MCP-only bundle for reusable mobile tooling. Doppler injects the licensed HeroUI Native Pro token without committing it.",
  },
];

const projectSkills = [
  "backend-review",
  "fix-review",
  "pumpd-architecture",
  "pumpd-ios-simulator",
  "pumpd-supabase-patterns",
  "pumpd-testing",
  "pumpd-ui-patterns",
  "quality",
  "sync-types",
];

const vendorTools = [
  ["Linear", "Official plugin / MCP", "Local Claude + Codex", "OAuth in each client; Cyrus remains a separate automation integration"],
  ["Supabase", "Official plugin / MCP + CLI", "Local clients + PUMPD project", "Use project-local MCP for local DB work; authenticate hosted access separately"],
  ["Sentry", "Official plugin / MCP", "Local Claude + Codex", "Use CLI only for release/build tasks that need it"],
  ["Context7", "MCP", "Project or plugin scope", "No owned fork; keep one definition per client/scope"],
  ["Expo", "Official plugin / skills + CLI", "PUMPD on demand", "Add MCP only when live EAS or simulator operations justify it"],
  ["Vercel", "Official plugin / MCP + CLI", "Web projects on demand", "Vendor-managed package; project/environment auth stays separate"],
  ["Doppler", "CLI first", "Projects that consume secrets", "Do not add an MCP until a concrete workflow outweighs the extra secret surface"],
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
          <a href="#vocabulary">Vocabulary</a>
          <a href="#model">Model</a>
          <a href="#setup">Our setup</a>
          <a href="#surfaces">Surfaces</a>
          <a href="#profiles">Profiles</a>
          <a href="#apm">APM</a>
        </nav>
        <span className="pilot-badge">Desired state · 2026.07</span>
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
            A visual map of what <strong>agent-tooling</strong> owns, what <strong>profiles and doctor</strong> track,
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
            <span>02</span><strong>Profiles</strong><small>desired state</small>
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
          <h2>Git stores the recipe. Profiles describe the kitchens. Each app still cooks in its own way.</h2>
        </div>
        <p>
          Nothing turns Claude and Codex into one product. The strategy gives them a shared source where possible,
          native configuration where necessary, and an explicit checklist where automation stops.
        </p>
      </section>

      <section className="section vocabulary-section" id="vocabulary">
        <div className="section-heading">
          <div>
            <p className="kicker">01 · Vocabulary</p>
            <h2>Every atom has one job</h2>
          </div>
          <p className="section-lede">
            The setup becomes manageable when packaging, procedure, tool access, authentication, and desired state are treated as different things.
          </p>
        </div>
        <div className="vocabulary-grid">
          {buildingBlocks.map((item, index) => (
            <article className="vocabulary-item" key={item.name}>
              <div className="vocabulary-index">{String(index + 1).padStart(2, "0")}</div>
              <div>
                <h3>{item.name}</h3>
                <strong>{item.role}</strong>
                <p>{item.boundary}</p>
                <small>Example · {item.example}</small>
              </div>
            </article>
          ))}
        </div>
        <div className="atom-equation" aria-label="Relationship between marketplace, plugin, skills and tools">
          <div><span>Catalog</span><strong>Marketplace</strong><small>find it</small></div>
          <i>→</i>
          <div><span>Package</span><strong>Plugin</strong><small>install it</small></div>
          <i>→</i>
          <div><span>Procedure</span><strong>Skill</strong><small>teach it</small></div>
          <b>+</b>
          <div><span>Access</span><strong>MCP / CLI</strong><small>do it</small></div>
          <b>+</b>
          <div><span>Permission</span><strong>Authentication</strong><small>authorize it</small></div>
        </div>
      </section>

      <section className="section model-section" id="model">
        <div className="section-heading">
          <div>
            <p className="kicker">02 · The operating model</p>
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
            <h3>Profiles + doctor</h3>
            <p>The small, read-only control plane for local and project desired state.</p>
            <ul>
              <li>Composable desired-state profiles</li>
              <li>Native inventory inspection</li>
              <li>Drift and missing-capability reports</li>
              <li>Manual hosted-account checks</li>
            </ul>
            <div className="layer-rule">Read-only by design. Installation and OAuth remain native actions.</div>
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
          <div><span>Desired state</span><strong>Composable profiles + checklists</strong></div>
          <div><span>Actual state</span><strong>Native clients + account UIs</strong></div>
          <div><span>Proof</span><strong>doctor, audit, and canaries</strong></div>
        </div>
      </section>

      <section className="section setup-section" id="setup">
        <div className="section-heading">
          <div>
            <p className="kicker">03 · Our actual setup</p>
            <h2>Small bundles, explicit projects</h2>
          </div>
          <p className="section-lede">
            The private catalog contains only workflows we own. Vendor tooling stays vendor-owned, while behavior required for PUMPD lives with the PUMPD checkout.
          </p>
        </div>

        <div className="setup-principle">
          <div><span>Private catalog</span><strong>4 owned plugins</strong><small>12 portable skills</small></div>
          <div><span>PUMPD checkout</span><strong>9 project skills</strong><small>committed for local + cloud</small></div>
          <div><span>Vendor catalogs</span><strong>7 core services</strong><small>installed and authenticated natively</small></div>
        </div>

        <div className="location-map" aria-label="Where configuration lives">
          <article>
            <span>Owned source</span>
            <h3>agent-tooling</h3>
            <pre><code>plugins/&lt;bundle&gt;/skills/{"<skill>"}{`\n`}.claude-plugin/marketplace.json{`\n`}.agents/plugins/marketplace.json{`\n`}profiles/*.json{`\n`}scripts/doctor</code></pre>
          </article>
          <article>
            <span>Project guarantee</span>
            <h3>PUMPD repository</h3>
            <pre><code>AGENTS.md + CLAUDE.md{`\n`}.agents/skills/{`\n`}.claude/skills/{`\n`}.claude/settings.json{`\n`}.mcp.json{`\n`}.codex/config.toml</code></pre>
          </article>
          <article>
            <span>Local actual state</span>
            <h3>Workstation homes</h3>
            <pre><code>~/.claude/{`\n`}  settings + plugins + MCPs{`\n`}~/.codex/{`\n`}  config + plugins + MCPs{`\n`}vendor CLI credentials</code></pre>
          </article>
          <article>
            <span>Hosted actual state</span>
            <h3>Accounts + cloud</h3>
            <pre><code>Claude.ai skills/connectors{`\n`}ChatGPT apps/connectors{`\n`}Claude cloud environments{`\n`}Codex cloud environments{`\n`}organization policy</code></pre>
          </article>
        </div>

        <div className="bundle-grid">
          {ownedBundles.map((bundle, index) => (
            <article className="bundle-card" key={bundle.name}>
              <div className="bundle-heading">
                <span>{String(index + 1).padStart(2, "0")}</span>
                <small>{bundle.scope}</small>
              </div>
              <h3>{bundle.name}</h3>
              <div className="skill-list">
                {bundle.skills.map((skill) => <code key={skill}>{skill}</code>)}
              </div>
              <p>{bundle.note}</p>
              <div className="bundle-owner">First-party package · Claude + Codex adapters</div>
            </article>
          ))}
        </div>

        <div className="project-owned">
          <div className="project-owned-copy">
            <p className="kicker">PUMPD project contract</p>
            <h3>Cloud-critical behavior travels with the repository</h3>
            <p>
              <code>.agents/skills</code> holds the canonical project skills. <code>.claude/skills</code> exposes the same in-repo content to Claude. <code>AGENTS.md</code> is shared guidance; <code>CLAUDE.md</code> is Claude&apos;s lightweight entry point.
            </p>
          </div>
          <div className="project-skill-list">
            {projectSkills.map((skill, index) => (
              <div key={skill}><span>{String(index + 1).padStart(2, "0")}</span><code>{skill}</code></div>
            ))}
          </div>
        </div>

        <div className="vendor-table-wrap" tabIndex={0} aria-label="Scrollable third-party tooling strategy">
          <table className="vendor-table">
            <thead><tr><th>Third-party tool</th><th>Preferred capability</th><th>Placement</th><th>Operating note</th></tr></thead>
            <tbody>
              {vendorTools.map((row) => (
                <tr key={row[0]}>{row.map((cell, index) => index === 0 ? <th key={cell}>{cell}</th> : <td key={cell}>{cell}</td>)}</tr>
              ))}
            </tbody>
          </table>
        </div>
      </section>

      <section className="section surfaces-section" id="surfaces">
        <div className="section-heading">
          <div>
            <p className="kicker">04 · Surface map</p>
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

      <section className="section profiles-section" id="profiles">
        <div className="section-heading">
          <div>
            <p className="kicker">05 · Profiles and doctor</p>
            <h2>Profiles answer “what should this context have?”</h2>
          </div>
          <p className="section-lede">
            A profile is a composable, secret-free checklist. The doctor compares it with observable files and native client state, then reports without changing anything.
          </p>
        </div>

        <div className="profile-diagram" aria-label="Profile composition diagram">
          <div className="profile-root">
            <span>Shared parent</span>
            <strong>base-workstation</strong>
            <small>agent-tooling catalogs + personal plugin + manual account checks</small>
          </div>
          <div className="profile-branch branch-left" aria-hidden="true" />
          <div className="profile-branch branch-right" aria-hidden="true" />
          <div className="profile-card profile-pumpd-project">
            <span>Project layer</span>
            <strong>pumpd-project</strong>
            <small>committed instructions, skills, MCPs, hooks, cloud canaries</small>
          </div>
          <div className="profile-plus" aria-hidden="true">+</div>
          <div className="profile-card profile-pumpd">
            <span>Effective context</span>
            <strong>pumpd-workstation</strong>
            <small>base + PUMPD project + cyrus/pumpd bundles + stable vendor plugins</small>
          </div>
          <div className="profile-card profile-wet">
            <span>Effective context</span>
            <strong>wet-in-seattle-workstation</strong>
            <small>base + wet-in-seattle bundle + Doppler-backed analytics-mcp</small>
          </div>
        </div>

        <div className="doctor-grid">
          <article><span className="doctor-status pass">PASS</span><h3>Observed and correct</h3><p>The expected file, plugin, marketplace, setting, or MCP declaration is present.</p></article>
          <article><span className="doctor-status warn">WARN</span><h3>Review drift</h3><p>An advisory mismatch exists, such as duplicate configuration or connector separation not yet enabled.</p></article>
          <article><span className="doctor-status fail">FAIL</span><h3>Required state missing</h3><p>A required capability is absent. The doctor identifies it but does not install it.</p></article>
          <article><span className="doctor-status manual">MANUAL</span><h3>A person must verify</h3><p>OAuth health, account stores, cloud access, and behavior cannot be proven from local configuration alone.</p></article>
        </div>
      </section>

      <section className="section journey-section" id="journeys">
        <div className="section-heading journey-heading">
          <div>
            <p className="kicker">06 · Trace a capability</p>
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

      <section className="section auth-section" id="auth">
        <div className="section-heading">
          <div>
            <p className="kicker">07 · Installation and authentication</p>
            <h2>Installed is not authenticated</h2>
          </div>
          <p className="section-lede">
            The repo can publish packages and describe expected connections. Permission is still granted by the exact local client, hosted account, or cloud environment that will use the service.
          </p>
        </div>

        <div className="auth-flow" aria-label="Capability installation and authentication flow">
          <article><span>01 · Source</span><strong>Git or vendor</strong><p>Contains public configuration and package content. Never live tokens.</p></article>
          <i aria-hidden="true">→</i>
          <article><span>02 · Install</span><strong>Native client</strong><p>Claude and Codex each record their own installed plugin or MCP declaration.</p></article>
          <i aria-hidden="true">→</i>
          <article><span>03 · Authorize</span><strong>Runtime identity</strong><p>OAuth, environment variables, or CLI credentials are granted on that surface.</p></article>
          <i aria-hidden="true">→</i>
          <article><span>04 · Verify</span><strong>Behavioral canary</strong><p>A real read or safe action proves the capability works—not merely that its name exists.</p></article>
        </div>

        <div className="auth-boundaries">
          <article>
            <p className="kicker">Local Claude Code</p>
            <h3>Authenticate in Claude Code</h3>
            <p>Use Claude Code&apos;s MCP management or supported login flow. Claude Desktop&apos;s general chat MCP configuration is a separate surface from the Code runtime embedded in the desktop app.</p>
          </article>
          <article>
            <p className="kicker">Local Codex</p>
            <h3>Authenticate in Codex</h3>
            <p>Use Codex desktop MCP settings or the supported Codex CLI login flow. A ChatGPT app connection does not automatically authenticate the local MCP.</p>
          </article>
          <article>
            <p className="kicker">Hosted accounts</p>
            <h3>Connect in Claude.ai or ChatGPT</h3>
            <p>Skills, apps, plugins, and connectors installed in an account remain account state. Git documents expectations but cannot click through OAuth or guarantee refresh.</p>
          </article>
          <article>
            <p className="kicker">Cloud coding</p>
            <h3>Provision the cloud environment</h3>
            <p>Fresh VMs receive the committed checkout and supported server-managed state. Local credentials do not travel; cloud environment variables and connector choices must be configured separately.</p>
          </article>
        </div>

        <div className="separation-callout">
          <span>Separation switch</span>
          <strong>Keep <code>disableClaudeAiConnectors</code> unset until local Linear, Supabase, Sentry, and PUMPD paths are authenticated and canaried.</strong>
          <p>Then enable it at user scope to keep hosted connectors in chat and deliberate local twins in Claude Code.</p>
        </div>
      </section>

      <section className="section apm-section" id="apm">
        <div className="section-heading">
          <div>
            <p className="kicker">08 · Microsoft APM</p>
            <h2>Useful package manager. Optional here.</h2>
          </div>
          <p className="section-lede">
            APM is an external package manager for agent instructions, skills, hooks, agents, plugins, and MCP declarations. We evaluated version 0.25.0, adopted its mental model, and deliberately did not make its CLI or generated files part of the required setup.
          </p>
        </div>

        <div className="apm-definition">
          <div>
            <p className="kicker">What APM is</p>
            <h3><code>apm.yml</code> describes dependencies. <code>apm.lock.yaml</code> pins what was resolved.</h3>
          </div>
          <div className="apm-command-flow" aria-label="APM command flow">
            <span>declare</span><strong>apm.yml</strong><i>→</i><span>resolve</span><strong>lockfile</strong><i>→</i><span>deploy</span><strong>target files</strong><i>→</i><span>prove</span><strong>apm audit</strong>
          </div>
        </div>

        <div className="lifecycle">
          {[
            ["01", "Author", "Shared skills live once in agent-tooling or the project"],
            ["02", "Adapt", "Thin native manifests expose Claude and Codex packages"],
            ["03", "Release", "Immutable Git revisions identify known-good content"],
            ["04", "Install", "Native marketplaces preserve client semantics"],
            ["05", "Inspect", "doctor reports missing, duplicate, or deferred state"],
            ["06", "Clean", "Backed-up native commands make explicit changes"],
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
            <p className="kicker">What APM adds</p>
            <h3>Dependency rigor across agent targets</h3>
            <div className="check-grid">
              {[
                "One declarative dependency manifest",
                "Commit-pinned transitive lockfile",
                "Multi-target skill and MCP deployment",
                "Per-file integrity hashes",
                "Drift and orphan detection",
                "Hidden-Unicode security scanning",
                "CI and SBOM-friendly audit output",
                "Pack and marketplace tooling",
              ].map((item) => <div key={item}><span>+</span>{item}</div>)}
            </div>
          </article>
          <article className="apm-does-not">
            <p className="kicker">Why it is not required now</p>
            <h3>Generation was not lossless for our policy</h3>
            <div className="check-grid">
              {[
                "Generated Claude versions conflict with Git-revision releases",
                "No native Codex plugin manifest in the spike",
                "Target-only metadata crossed package boundaries",
                "Hooks still required target-aware rewrites",
                "Hosted account stores remain unsynchronized",
                "OAuth and secrets still remain per runtime",
                "Native catalogs are already small and validated",
                "A third required abstraction would add maintenance",
              ].map((item) => <div key={item}><span>×</span>{item}</div>)}
            </div>
          </article>
        </div>

        <div className="apm-decision">
          <div><span>Current authority</span><strong>Hand-authored Claude + Codex catalogs and manifests</strong></div>
          <div><span>Current control plane</span><strong>Profiles + read-only doctor + native canaries</strong></div>
          <div><span>Possible later use</span><strong>Consumer lockfile, provenance, Unicode scan, drift audit</strong></div>
          <div><span>Revisit trigger</span><strong>Native maintenance cost exceeds the extra abstraction</strong></div>
        </div>

        <div className="command-card">
          <div className="command-copy">
            <p className="kicker">The current workstation loop</p>
            <h3>Change source, validate, inspect, apply natively.</h3>
            <p>There is no general automatic apply. The doctor stays read-only; mutations are narrow native commands with a rollback snapshot.</p>
          </div>
          <pre aria-label="Example native workflow"><code><span className="prompt">$</span> ./scripts/validate
<span className="comment"># validate both catalogs and isolated native installs</span>

<span className="prompt">$</span> ./scripts/doctor pumpd-workstation
<span className="comment"># inspect desired state without changing anything</span>

<span className="prompt">$</span> claude plugin update plugin@agent-tooling
<span className="comment"># apply one reviewed Claude package update</span>

<span className="prompt">$</span> codex plugin add plugin@agent-tooling --json
<span className="comment"># apply the matching Codex package natively</span></code></pre>
        </div>
      </section>

      <section className="section matrix-section">
        <div className="section-heading">
          <div>
            <p className="kicker">09 · Ownership matrix</p>
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
                <th>Profile / doctor</th>
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
          <p className="kicker">10 · Placement rules</p>
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
            <div><span>2</span><strong>Validate and apply</strong><small>through each native manager</small></div>
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
