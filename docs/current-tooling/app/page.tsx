type Side = {
  detail: string;
  items?: string[];
  disabled?: boolean;
};

type ComparisonRow = {
  name: string;
  state: "match" | "different" | "claude-only" | "codex-only";
  claude?: Side;
  codex?: Side;
};

const sharedOwnedPlugins: ComparisonRow[] = [
  ["personal", "user", "user-wide"],
  ["developer-workflows", "user", "user-wide"],
  ["mobile-development", "user", "user-wide"],
  ["pumpd-workflows", "PUMPD project", "user-wide"],
  ["cyrus-workflows", "PUMPD project", "user-wide"],
  ["wet-in-seattle", "IAWIS project", "user-wide"],
].map(([name, claude, codex]) => ({
  name,
  state: claude === "user" && codex === "user-wide" ? "match" : "different",
  claude: { detail: `agent-tooling · ${claude}` },
  codex: { detail: `agent-tooling · ${codex}` },
})) as ComparisonRow[];

const pluginRows: ComparisonRow[] = [
  ...sharedOwnedPlugins,
  {
    name: "linear",
    state: "different",
    claude: { detail: "Anthropic official · project" },
    codex: { detail: "OpenAI curated · user-wide" },
  },
  {
    name: "sentry",
    state: "different",
    claude: { detail: "Anthropic official · project" },
    codex: { detail: "OpenAI curated · user-wide" },
  },
  {
    name: "supabase",
    state: "different",
    claude: { detail: "Anthropic official · project" },
    codex: { detail: "OpenAI curated · user-wide" },
  },
  ...[
    "skill-creator",
    "code-review",
    "code-simplifier",
    "context7",
    "frontend-design",
    "playwright",
    "security-guidance",
    "shopify-ai-toolkit",
  ].map((name) => ({
    name,
    state: "claude-only" as const,
    claude: { detail: `Anthropic official · ${name === "skill-creator" ? "user" : "project"}` },
  })),
  {
    name: "react-native-best-practices",
    state: "claude-only",
    claude: { detail: "Callstack · project" },
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
    codex: { detail: "OpenAI runtime · user-wide" },
  })),
  ...["vercel", "github", "build-ios-apps", "expo"].map((name) => ({
    name,
    state: "codex-only" as const,
    codex: { detail: "OpenAI curated · user-wide" },
  })),
];

const ownedSkillRows: ComparisonRow[] = [
  ["obsidian-vault", "personal"],
  ["dad-daily-update", "personal"],
  ["personal-task", "personal"],
  ["personal-task-done", "personal"],
  ["thermo-nuclear-code-quality-review", "developer-workflows"],
  ["cyrus-setup", "cyrus-workflows"],
  ["pumpd-research", "cyrus-workflows"],
  ["pumpd-plan", "cyrus-workflows"],
  ["pumpd-review", "cyrus-workflows"],
  ["pumpd-decompose", "cyrus-workflows"],
  ["log-learning", "cyrus-workflows"],
  ["pumpd-retro", "cyrus-workflows"],
  ["pumpd-local-cleanup", "pumpd-workflows"],
  ["iawis-weekly-report", "wet-in-seattle"],
].map(([name, plugin]) => ({
  name,
  state: "match",
  claude: { detail: `agent-tooling · ${plugin}` },
  codex: { detail: `agent-tooling · ${plugin}` },
})) as ComparisonRow[];

const vendorSkillRows: ComparisonRow[] = [
  {
    name: "Supabase skills",
    state: "match",
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
    claude: { detail: "2 skills", items: ["skill-creator", "frontend-design"] },
  },
  {
    name: "Callstack React Native skills",
    state: "claude-only",
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
    claude: { detail: "None · ~/.claude/skills is clean" },
    codex: { detail: "2 skills", items: ["chronicle", "figma"] },
  },
  {
    name: "OpenAI runtime skills",
    state: "codex-only",
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
    codex: { detail: "4 skills", items: ["github", "gh-address-comments", "gh-fix-ci", "yeet"] },
  },
  {
    name: "Apple skills",
    state: "codex-only",
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
    codex: { detail: "2 skills", items: ["linear", "sentry"] },
  },
  {
    name: "Vercel skills",
    state: "codex-only",
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
    claude: { detail: "mobile-development plugin" },
    codex: { detail: "mobile-development plugin" },
  },
  {
    name: "heroui-native",
    state: "match",
    claude: { detail: "mobile-development plugin" },
    codex: { detail: "mobile-development plugin" },
  },
  {
    name: "heroui-native-pro",
    state: "match",
    claude: { detail: "mobile-development plugin" },
    codex: { detail: "mobile-development plugin" },
  },
  {
    name: "analytics-mcp",
    state: "different",
    claude: { detail: "IAWIS project" },
    codex: { detail: "wet-in-seattle plugin" },
  },
  {
    name: "context7",
    state: "match",
    claude: { detail: "PUMPD project" },
    codex: { detail: "PUMPD project" },
  },
  {
    name: "playwright",
    state: "match",
    claude: { detail: "PUMPD project" },
    codex: { detail: "PUMPD project" },
  },
  {
    name: "linear",
    state: "different",
    claude: { detail: "PUMPD project" },
    codex: { detail: "vendor runtime" },
  },
  {
    name: "supabase",
    state: "claude-only",
    claude: { detail: "base / user" },
  },
  {
    name: "sentry",
    state: "claude-only",
    claude: { detail: "PUMPD project" },
  },
  {
    name: "supabase_local",
    state: "claude-only",
    claude: { detail: "PUMPD project" },
  },
  {
    name: "shadcn",
    state: "claude-only",
    claude: { detail: "IAWIS project" },
  },
  ...["node_repl", "sites-design-picker", "xcodebuildmcp", "github"].map((name) => ({
    name,
    state: "codex-only" as const,
    codex: { detail: "runtime / vendor" },
  })),
  {
    name: "figma",
    state: "codex-only",
    codex: { detail: "direct user configuration" },
  },
  {
    name: "heroui-pro",
    state: "codex-only",
    codex: { detail: "direct user config · retained legacy exception" },
  },
  {
    name: "computer-use",
    state: "codex-only",
    codex: { detail: "direct user configuration", disabled: true },
  },
];

const labels = {
  match: "Match",
  different: "Different setup",
  "claude-only": "Claude only",
  "codex-only": "Codex only",
};

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

function ComparisonTable({ rows }: { rows: ComparisonRow[] }) {
  if (rows.length === 0) {
    return (
      <div className="empty-state">
        <strong>No project skills installed</strong>
        <p>Claude Code and Codex are both clean at the PUMPD project level.</p>
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
            <span className={`state-pill ${row.state}`}>{labels[row.state]}</span>
          </div>
          <SideCell side={row.claude} client="claude" />
          <SideCell side={row.codex} client="codex" />
        </div>
      ))}
    </div>
  );
}

function Section({
  title,
  description,
  rows,
}: {
  title: string;
  description: string;
  rows: ComparisonRow[];
}) {
  return (
    <section className="inventory-section">
      <header>
        <h2>{title}</h2>
        <p>{description}</p>
      </header>
      <ComparisonTable rows={rows} />
    </section>
  );
}

export default function Home() {
  return (
    <main>
      <header className="page-header">
        <p className="eyebrow">CURRENT STATE · VERIFIED JULY 17, 2026</p>
        <h1>Claude Code vs. Codex</h1>
        <p className="lede">
          Read straight across each row. Matches stay neutral; differences are highlighted.
        </p>
        <div className="legend" aria-label="Comparison legend">
          <span className="state-pill match">Match</span>
          <span className="state-pill different">Different setup</span>
          <span className="state-pill claude-only">Claude only</span>
          <span className="state-pill codex-only">Codex only</span>
        </div>
        <p className="scope-note">
          Claude.ai and ChatGPT hosted apps/connectors are account-managed and are not included here.
        </p>
      </header>

      <Section
        title="Plugins"
        description="Bundles installed into each coding client. Scope and provider differences are called out even when both clients have the same capability."
        rows={pluginRows}
      />
      <Section
        title="Our skills"
        description="Skills authored in agent-tooling. These should match across Claude Code and Codex."
        rows={ownedSkillRows}
      />
      <Section
        title="Official & vendor skills"
        description="Large vendor packs are compared by suite. Expand any cell to see every skill name."
        rows={vendorSkillRows}
      />
      <Section
        title="PUMPD project skills"
        description="Reserved for future project-specific skills. This section stays visible even when the inventory is empty."
        rows={projectSkillRows}
      />
      <Section
        title="MCP servers"
        description="Servers are matched by capability; highlighted rows show different ownership, scope, or availability."
        rows={mcpRows}
      />
    </main>
  );
}
