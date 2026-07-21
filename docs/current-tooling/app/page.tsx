"use client";

import { useMemo, useState } from "react";

type Side = {
  detail: string;
  items?: string[];
  disabled?: boolean;
};

type Project = "global" | "pumpd" | "iawis";
type ProjectFilter = "all" | Project;
type State = "match" | "different" | "claude-only" | "codex-only";
type StatusFilter = "all" | State;
type SortMode = "smart" | "name" | "differences";

type ComparisonRow = {
  name: string;
  state: State;
  projects: Project[];
  claude?: Side;
  codex?: Side;
};

type InventorySection = {
  id: string;
  title: string;
  description: string;
  rows: ComparisonRow[];
  emptyTitle?: string;
  emptyDescription?: string;
};

const projectLabels: Record<Project, string> = {
  global: "Global",
  pumpd: "PUMPD project",
  iawis: "IAWIS project",
};

const labels: Record<State, string> = {
  match: "Match",
  different: "Different setup",
  "claude-only": "Claude only",
  "codex-only": "Codex only",
};

const sharedOwnedPlugins: ComparisonRow[] = [
  ["personal", "user", "user-wide", ["global"]],
  ["developer-workflows", "user", "user-wide", ["global"]],
  ["mobile-development", "user", "user-wide", ["global"]],
  ["pumpd-workflows", "PUMPD project", "user-wide", ["pumpd"]],
  ["cyrus-workflows", "PUMPD project", "user-wide", ["pumpd"]],
  ["wet-in-seattle", "IAWIS project", "user-wide", ["iawis"]],
].map(([name, claude, codex, projects]) => ({
  name,
  state: claude === "user" && codex === "user-wide" ? "match" : "different",
  projects,
  claude: { detail: `agent-tooling · ${claude}` },
  codex: { detail: `agent-tooling · ${codex}` },
})) as ComparisonRow[];

const pluginRows: ComparisonRow[] = [
  ...sharedOwnedPlugins,
  {
    name: "linear",
    state: "different",
    projects: ["global", "pumpd"],
    claude: { detail: "Anthropic official · PUMPD project" },
    codex: { detail: "OpenAI curated · user-wide" },
  },
  {
    name: "sentry",
    state: "different",
    projects: ["global", "pumpd"],
    claude: { detail: "Anthropic official · PUMPD project" },
    codex: { detail: "OpenAI curated · user-wide" },
  },
  {
    name: "supabase",
    state: "different",
    projects: ["global", "pumpd"],
    claude: { detail: "Anthropic official · PUMPD project" },
    codex: { detail: "OpenAI curated · user-wide" },
  },
  ...[
    ["skill-creator", "user", ["global"]],
    ["code-review", "project", ["pumpd"]],
    ["code-simplifier", "project", ["pumpd"]],
    ["context7", "project", ["pumpd"]],
    ["frontend-design", "project", ["pumpd"]],
    ["playwright", "project", ["pumpd"]],
    ["security-guidance", "project", ["pumpd"]],
    ["shopify-ai-toolkit", "project", ["pumpd"]],
  ].map(([name, scope, projects]) => ({
    name,
    state: "claude-only" as const,
    projects,
    claude: { detail: `Anthropic official · ${scope}` },
  })) as ComparisonRow[],
  {
    name: "react-native-best-practices",
    state: "claude-only",
    projects: ["pumpd"],
    claude: { detail: "Callstack · PUMPD project" },
  },
  ...[
    "documents",
    "pdf",
    "spreadsheets",
    "presentations",
    "template-creator",
    "sites",
    "browser",
    "chrome",
    "visualize",
  ].map((name) => ({
    name,
    state: "codex-only" as const,
    projects: ["global"] as Project[],
    codex: { detail: "OpenAI runtime · user-wide" },
  })),
  ...["vercel", "github", "build-ios-apps", "expo"].map((name) => ({
    name,
    state: "codex-only" as const,
    projects: ["global"] as Project[],
    codex: { detail: "OpenAI curated · user-wide" },
  })),
];

const ownedSkillRows: ComparisonRow[] = [
  ["obsidian-vault", "personal", ["global"]],
  ["dad-daily-update", "personal", ["global"]],
  ["personal-task", "personal", ["global"]],
  ["personal-task-done", "personal", ["global"]],
  ["thermo-nuclear-code-quality-review", "developer-workflows", ["global"]],
  ["cyrus-setup", "cyrus-workflows", ["pumpd"]],
  ["pumpd-research", "cyrus-workflows", ["pumpd"]],
  ["pumpd-plan", "cyrus-workflows", ["pumpd"]],
  ["pumpd-review", "cyrus-workflows", ["pumpd"]],
  ["pumpd-decompose", "cyrus-workflows", ["pumpd"]],
  ["log-learning", "cyrus-workflows", ["pumpd"]],
  ["pumpd-retro", "cyrus-workflows", ["pumpd"]],
  ["pumpd-local-cleanup", "pumpd-workflows", ["pumpd"]],
  ["iawis-weekly-report", "wet-in-seattle", ["iawis"]],
].map(([name, plugin, projects]) => ({
  name,
  state: "match",
  projects,
  claude: { detail: `agent-tooling · ${plugin}` },
  codex: { detail: `agent-tooling · ${plugin}` },
})) as ComparisonRow[];

const vendorSkillRows: ComparisonRow[] = [
  {
    name: "Supabase skills",
    state: "match",
    projects: ["global", "pumpd"],
    claude: {
      detail: "2 skills",
      items: ["supabase", "supabase-postgres-best-practices"],
    },
    codex: {
      detail: "2 skills",
      items: ["supabase", "supabase-postgres-best-practices"],
    },
  },
  {
    name: "Sentry skills",
    state: "different",
    projects: ["global", "pumpd"],
    claude: {
      detail: "10 skills",
      items: [
        "sentry-create-alert",
        "sentry-debug-issue",
        "sentry-feature-setup",
        "sentry-get-started",
        "sentry-instrument",
        "sentry-otel-exporter-setup",
        "sentry-sdk-upgrade",
        "sentry-setup-ai-monitoring",
        "sentry-snapshots-cocoa",
        "sentry-workflow",
      ],
    },
    codex: { detail: "1 skill", items: ["sentry"] },
  },
  {
    name: "Anthropic skills",
    state: "claude-only",
    projects: ["global", "pumpd"],
    claude: { detail: "2 skills", items: ["skill-creator", "frontend-design"] },
  },
  {
    name: "Callstack React Native skills",
    state: "claude-only",
    projects: ["pumpd"],
    claude: {
      detail: "14 skills",
      items: [
        "agent-device",
        "assess-react-native-migration",
        "create-react-native-library",
        "dogfood",
        "github",
        "github-actions",
        "react-native-best-practices",
        "react-native-brownfield-migration",
        "react-native-testing",
        "react-native-tv-best-practices",
        "react-navigation",
        "upgrading-react-native",
        "validate-skills",
        "vercel-react-native-skills",
      ],
    },
  },
  {
    name: "Shopify skills",
    state: "claude-only",
    projects: ["pumpd"],
    claude: {
      detail: "20 skills",
      items: [
        "shopify-admin",
        "shopify-app-store-review",
        "shopify-custom-data",
        "shopify-customer",
        "shopify-dev",
        "shopify-functions",
        "shopify-hydrogen",
        "shopify-liquid",
        "shopify-onboarding-dev",
        "shopify-onboarding-merchant",
        "shopify-partner",
        "shopify-payments-apps",
        "shopify-polaris-admin-extensions",
        "shopify-polaris-app-home",
        "shopify-polaris-checkout-extensions",
        "shopify-polaris-customer-account-extensions",
        "shopify-pos-ui",
        "shopify-storefront-graphql",
        "shopify-use-shopify-cli",
        "ucp",
      ],
    },
  },
  {
    name: "Standalone personal skills",
    state: "codex-only",
    projects: ["global"],
    claude: { detail: "None · ~/.claude/skills is clean" },
    codex: { detail: "2 skills", items: ["chronicle", "figma"] },
  },
  {
    name: "OpenAI runtime skills",
    state: "codex-only",
    projects: ["global"],
    codex: {
      detail: "11 skills",
      items: [
        "documents",
        "pdf",
        "spreadsheets",
        "excel-live-control",
        "presentations",
        "template-creator",
        "sites-building",
        "sites-hosting",
        "control-in-app-browser",
        "control-chrome",
        "visualize",
      ],
    },
  },
  {
    name: "GitHub skills",
    state: "codex-only",
    projects: ["global"],
    codex: { detail: "4 skills", items: ["github", "gh-address-comments", "gh-fix-ci", "yeet"] },
  },
  {
    name: "Apple skills",
    state: "codex-only",
    projects: ["global"],
    codex: {
      detail: "9 skills",
      items: [
        "ios-app-intents",
        "ios-debugger-agent",
        "ios-ettrace-performance",
        "ios-memgraph-leaks",
        "ios-simulator-browser",
        "swiftui-liquid-glass",
        "swiftui-performance-audit",
        "swiftui-ui-patterns",
        "swiftui-view-refactor",
      ],
    },
  },
  {
    name: "Expo skills",
    state: "codex-only",
    projects: ["global"],
    codex: {
      detail: "13 skills",
      items: [
        "building-native-ui",
        "codex-expo-run-actions",
        "expo-api-routes",
        "expo-cicd-workflows",
        "expo-deployment",
        "expo-dev-client",
        "expo-module",
        "expo-tailwind-setup",
        "expo-ui-jetpack-compose",
        "expo-ui-swift-ui",
        "native-data-fetching",
        "upgrading-expo",
        "use-dom",
      ],
    },
  },
  {
    name: "Other OpenAI curated skills",
    state: "codex-only",
    projects: ["global"],
    codex: { detail: "2 skills", items: ["linear", "sentry"] },
  },
  {
    name: "Vercel skills",
    state: "codex-only",
    projects: ["global"],
    codex: {
      detail: "47 skills",
      items: [
        "agent-browser",
        "agent-browser-verify",
        "ai-elements",
        "ai-gateway",
        "ai-generation-persistence",
        "ai-sdk",
        "auth",
        "bootstrap",
        "chat-sdk",
        "cms",
        "cron-jobs",
        "deployments-cicd",
        "email",
        "env-vars",
        "geist",
        "geistdocs",
        "investigation-mode",
        "json-render",
        "marketplace",
        "micro",
        "ncc",
        "next-forge",
        "nextjs",
        "observability",
        "payments",
        "react-best-practices",
        "routing-middleware",
        "runtime-cache",
        "satori",
        "shadcn",
        "sign-in-with-vercel",
        "swr",
        "turbopack",
        "turborepo",
        "v0-dev",
        "vercel-agent",
        "vercel-api",
        "vercel-cli",
        "vercel-firewall",
        "vercel-flags",
        "vercel-functions",
        "vercel-queues",
        "vercel-sandbox",
        "vercel-services",
        "vercel-storage",
        "verification",
        "workflow",
      ],
    },
  },
];

const projectSkillRows: ComparisonRow[] = [];

const mcpRows: ComparisonRow[] = [
  {
    name: "ios-simulator-mcp",
    state: "match",
    projects: ["global"],
    claude: { detail: "mobile-development plugin" },
    codex: { detail: "mobile-development plugin" },
  },
  {
    name: "heroui-native",
    state: "match",
    projects: ["global"],
    claude: { detail: "mobile-development plugin" },
    codex: { detail: "mobile-development plugin" },
  },
  {
    name: "heroui-native-pro",
    state: "match",
    projects: ["global"],
    claude: { detail: "mobile-development plugin · Doppler" },
    codex: { detail: "mobile-development plugin · Doppler" },
  },
  {
    name: "heroui-pro",
    state: "match",
    projects: ["global"],
    claude: { detail: "developer-workflows plugin · Doppler" },
    codex: { detail: "developer-workflows plugin · Doppler" },
  },
  {
    name: "analytics-mcp",
    state: "different",
    projects: ["iawis"],
    claude: { detail: "IAWIS project" },
    codex: { detail: "wet-in-seattle plugin" },
  },
  {
    name: "context7",
    state: "match",
    projects: ["pumpd"],
    claude: { detail: "PUMPD project" },
    codex: { detail: "PUMPD project" },
  },
  {
    name: "playwright",
    state: "match",
    projects: ["pumpd"],
    claude: { detail: "PUMPD project" },
    codex: { detail: "PUMPD project" },
  },
  {
    name: "linear",
    state: "different",
    projects: ["global", "pumpd"],
    claude: { detail: "PUMPD project" },
    codex: { detail: "vendor runtime" },
  },
  {
    name: "supabase",
    state: "claude-only",
    projects: ["global"],
    claude: { detail: "base / user" },
  },
  {
    name: "sentry",
    state: "claude-only",
    projects: ["pumpd"],
    claude: { detail: "PUMPD project" },
  },
  {
    name: "supabase_local",
    state: "claude-only",
    projects: ["pumpd"],
    claude: { detail: "PUMPD project" },
  },
  {
    name: "shadcn",
    state: "claude-only",
    projects: ["iawis"],
    claude: { detail: "IAWIS project" },
  },
  ...["node_repl", "sites-design-picker", "xcodebuildmcp", "github"].map((name) => ({
    name,
    state: "codex-only" as const,
    projects: ["global"] as Project[],
    codex: { detail: "runtime / vendor" },
  })),
  {
    name: "figma",
    state: "codex-only",
    projects: ["global"],
    codex: { detail: "direct user configuration" },
  },
  {
    name: "computer-use",
    state: "codex-only",
    projects: ["global"],
    codex: { detail: "direct user configuration", disabled: true },
  },
];

const sections: InventorySection[] = [
  {
    id: "plugins",
    title: "Plugins",
    description:
      "Bundles installed into each coding client. Scope and provider differences are called out even when both clients have the same capability.",
    rows: pluginRows,
  },
  {
    id: "our-skills",
    title: "Our skills",
    description: "Skills authored in agent-tooling. These should match across Claude Code and Codex.",
    rows: ownedSkillRows,
  },
  {
    id: "vendor-skills",
    title: "Official & vendor skills",
    description: "Large vendor packs are compared by suite. Expand any cell to see every skill name.",
    rows: vendorSkillRows,
  },
  {
    id: "project-skills",
    title: "PUMPD project skills",
    description: "Reserved for future project-specific skills. This section stays visible even when the inventory is empty.",
    rows: projectSkillRows,
    emptyTitle: "No project skills installed",
    emptyDescription: "Claude Code and Codex are both clean at the PUMPD project level.",
  },
  {
    id: "mcps",
    title: "MCP servers",
    description: "Servers are matched by capability; highlighted rows show different ownership, scope, or availability.",
    rows: mcpRows,
  },
];

function matchesText(row: ComparisonRow, query: string) {
  if (!query) return true;
  const text = [
    row.name,
    labels[row.state],
    ...row.projects.map((project) => projectLabels[project]),
    row.claude?.detail,
    ...(row.claude?.items ?? []),
    row.codex?.detail,
    ...(row.codex?.items ?? []),
  ]
    .filter(Boolean)
    .join(" ")
    .toLowerCase();
  return text.includes(query);
}

function matchesProject(row: ComparisonRow, project: ProjectFilter) {
  if (project === "all") return true;
  if (project === "global") return row.projects.includes("global");
  return row.projects.includes("global") || row.projects.includes(project);
}

function sortRows(rows: ComparisonRow[], sort: SortMode, project: ProjectFilter) {
  const stateRank: Record<State, number> = {
    different: 0,
    "claude-only": 1,
    "codex-only": 2,
    match: 3,
  };

  return [...rows].sort((a, b) => {
    if (sort === "name") return a.name.localeCompare(b.name);
    if (sort === "differences") {
      return stateRank[a.state] - stateRank[b.state] || a.name.localeCompare(b.name);
    }

    if (project === "pumpd" || project === "iawis") {
      const aProject = a.projects.includes(project) ? 0 : 1;
      const bProject = b.projects.includes(project) ? 0 : 1;
      if (aProject !== bProject) return aProject - bProject;
    }

    return stateRank[a.state] - stateRank[b.state] || a.name.localeCompare(b.name);
  });
}

function SideCell({ side, client }: { side?: Side; client: "claude" | "codex" }) {
  if (!side) {
    return <div className={`side-cell empty ${client}`}>—</div>;
  }

  return (
    <div className={`side-cell ${client}`}>
      <span className="installed-mark" aria-hidden="true">✓</span>
      <div>
        <p>{side.detail}</p>
        {side.disabled ? <span className="disabled-pill">Disabled</span> : null}
        {side.items ? (
          <details>
            <summary>Show names</summary>
            <ul>
              {side.items.map((item) => <li key={item}>{item}</li>)}
            </ul>
          </details>
        ) : null}
      </div>
    </div>
  );
}

function ComparisonTable({
  rows,
  emptyTitle,
  emptyDescription,
}: {
  rows: ComparisonRow[];
  emptyTitle: string;
  emptyDescription: string;
}) {
  if (rows.length === 0) {
    return (
      <div className="empty-state">
        <strong>{emptyTitle}</strong>
        <p>{emptyDescription}</p>
      </div>
    );
  }

  return (
    <div className="comparison-table">
      <div className="table-header" aria-hidden="true">
        <span>Capability</span>
        <span className="claude-label">Claude Code</span>
        <span className="codex-label">Codex</span>
      </div>
      {rows.map((row) => (
        <div className={`comparison-row ${row.state}`} key={row.name}>
          <div className="capability-name">
            <strong>{row.name}</strong>
            <div className="row-pills">
              <span className={`state-pill ${row.state}`}>{labels[row.state]}</span>
              {row.projects.map((project) => (
                <span className={`project-pill ${project}`} key={project}>
                  {projectLabels[project]}
                </span>
              ))}
            </div>
          </div>
          <SideCell side={row.claude} client="claude" />
          <SideCell side={row.codex} client="codex" />
        </div>
      ))}
    </div>
  );
}

function Section({
  section,
  rows,
  isOpen,
  onToggle,
  hasActiveFilters,
}: {
  section: InventorySection;
  rows: ComparisonRow[];
  isOpen: boolean;
  onToggle: () => void;
  hasActiveFilters: boolean;
}) {
  const emptyTitle = section.rows.length === 0
    ? section.emptyTitle ?? "Nothing installed"
    : "No matching items";
  const emptyDescription = section.rows.length === 0
    ? section.emptyDescription ?? "This section is intentionally empty."
    : hasActiveFilters
      ? "Try a different project, status, or search term."
      : "Nothing is available in this section.";

  return (
    <section className="inventory-section">
      <button
        className="section-toggle"
        type="button"
        aria-expanded={isOpen}
        aria-controls={`${section.id}-content`}
        onClick={onToggle}
      >
        <span>
          <span className="section-heading-line">
            <h2>{section.title}</h2>
            <span className="count-pill">{rows.length}</span>
          </span>
          <span className="section-description">{section.description}</span>
        </span>
        <span className="chevron" aria-hidden="true">{isOpen ? "−" : "+"}</span>
      </button>
      {isOpen ? (
        <div id={`${section.id}-content`}>
          <ComparisonTable
            rows={rows}
            emptyTitle={emptyTitle}
            emptyDescription={emptyDescription}
          />
        </div>
      ) : null}
    </section>
  );
}

export default function Home() {
  const [project, setProject] = useState<ProjectFilter>("all");
  const [status, setStatus] = useState<StatusFilter>("all");
  const [sort, setSort] = useState<SortMode>("smart");
  const [query, setQuery] = useState("");
  const [openSections, setOpenSections] = useState<Record<string, boolean>>(
    Object.fromEntries(sections.map((section) => [section.id, true])),
  );

  const filteredSections = useMemo(() => {
    const normalizedQuery = query.trim().toLowerCase();
    return sections.map((section) => ({
      ...section,
      filteredRows: sortRows(
        section.rows.filter(
          (row) =>
            matchesProject(row, project) &&
            (status === "all" || row.state === status) &&
            matchesText(row, normalizedQuery),
        ),
        sort,
        project,
      ),
    }));
  }, [project, query, sort, status]);

  const visibleCount = filteredSections.reduce(
    (count, section) => count + section.filteredRows.length,
    0,
  );
  const hasActiveFilters = project !== "all" || status !== "all" || query.trim() !== "";

  const setAllSections = (isOpen: boolean) => {
    setOpenSections(Object.fromEntries(sections.map((section) => [section.id, isOpen])));
  };

  return (
    <main>
      <header className="page-header">
        <p className="eyebrow">CURRENT STATE · VERIFIED JULY 17, 2026</p>
        <h1>Claude Code vs. Codex</h1>
        <p className="lede">
          Read straight across each row, or choose a project to see everything available in that context.
        </p>
        <div className="legend" aria-label="Comparison legend">
          <span className="state-pill match">Match</span>
          <span className="state-pill different">Different setup</span>
          <span className="state-pill claude-only">Claude only</span>
          <span className="state-pill codex-only">Codex only</span>
          <span className="project-pill pumpd">PUMPD project</span>
          <span className="project-pill iawis">IAWIS project</span>
          <span className="project-pill global">Global</span>
        </div>
        <p className="scope-note">
          Claude.ai and ChatGPT hosted apps/connectors are account-managed and are not included here.
        </p>
      </header>

      <section className="filter-panel" aria-label="Inventory filters">
        <div className="filter-panel-header">
          <div>
            <p className="filter-kicker">Project context</p>
            <h2>What can I use here?</h2>
          </div>
          <p className="result-count">{visibleCount} capabilities shown</p>
        </div>

        <div className="project-filters" role="group" aria-label="Filter by project">
          {[
            ["all", "Everything"],
            ["global", "Global only"],
            ["pumpd", "PUMPD"],
            ["iawis", "IAWIS"],
          ].map(([value, label]) => (
            <button
              className={`project-filter ${value} ${project === value ? "active" : ""}`}
              type="button"
              aria-pressed={project === value}
              onClick={() => setProject(value as ProjectFilter)}
              key={value}
            >
              {label}
            </button>
          ))}
        </div>
        <p className="filter-help">
          Project views include both project-specific tooling and global tooling available everywhere.
        </p>

        <div className="filter-grid">
          <label className="search-control">
            <span>Search</span>
            <input
              type="search"
              value={query}
              onChange={(event) => setQuery(event.target.value)}
              placeholder="Plugin, skill, MCP, provider…"
            />
          </label>
          <label>
            <span>Status</span>
            <select value={status} onChange={(event) => setStatus(event.target.value as StatusFilter)}>
              <option value="all">All statuses</option>
              <option value="match">Match</option>
              <option value="different">Different setup</option>
              <option value="claude-only">Claude only</option>
              <option value="codex-only">Codex only</option>
            </select>
          </label>
          <label>
            <span>Sort</span>
            <select value={sort} onChange={(event) => setSort(event.target.value as SortMode)}>
              <option value="smart">Smart / project first</option>
              <option value="differences">Differences first</option>
              <option value="name">Name A–Z</option>
            </select>
          </label>
          <div className="section-actions" aria-label="Table visibility">
            <span>Tables</span>
            <div>
              <button type="button" onClick={() => setAllSections(true)}>Expand all</button>
              <button type="button" onClick={() => setAllSections(false)}>Collapse all</button>
            </div>
          </div>
        </div>
      </section>

      {filteredSections.map((section) => (
        <Section
          section={section}
          rows={section.filteredRows}
          isOpen={openSections[section.id]}
          onToggle={() =>
            setOpenSections((current) => ({
              ...current,
              [section.id]: !current[section.id],
            }))
          }
          hasActiveFilters={hasActiveFilters}
          key={section.id}
        />
      ))}
    </main>
  );
}
