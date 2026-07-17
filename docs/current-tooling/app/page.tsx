type ListGroup = {
  title: string;
  note?: string;
  items: string[];
};

const ownedSkills = [
  "obsidian-vault",
  "dad-daily-update",
  "personal-task",
  "personal-task-done",
  "thermo-nuclear-code-quality-review",
  "cyrus-setup",
  "pumpd-research",
  "pumpd-plan",
  "pumpd-review",
  "pumpd-decompose",
  "log-learning",
  "pumpd-retro",
  "pumpd-local-cleanup",
  "iawis-weekly-report",
];

const pumpdWorktreeSkills = [
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

const claudePlugins: ListGroup[] = [
  {
    title: "Our plugins · agent-tooling",
    items: [
      "personal · user",
      "developer-workflows · user",
      "mobile-development · user",
      "cyrus-workflows · PUMPD project",
      "pumpd-workflows · PUMPD project",
      "wet-in-seattle · IAWIS project",
    ],
  },
  {
    title: "Anthropic official",
    items: [
      "skill-creator · user",
      "code-review · project",
      "code-simplifier · project",
      "context7 · project",
      "frontend-design · project",
      "linear · project",
      "playwright · project",
      "security-guidance · project",
      "sentry · project",
      "shopify-ai-toolkit · project",
      "supabase · project",
    ],
  },
  {
    title: "Third party",
    items: ["react-native-best-practices · Callstack · project"],
  },
];

const claudeMcps: ListGroup[] = [
  {
    title: "Base / user",
    items: [
      "supabase",
      "ios-simulator-mcp · from mobile-development",
      "heroui-native · from mobile-development",
      "heroui-native-pro · from mobile-development",
    ],
  },
  {
    title: "PUMPD project",
    items: ["context7", "linear", "playwright", "sentry", "supabase_local"],
  },
  {
    title: "IAWIS project",
    items: ["analytics-mcp", "shadcn"],
  },
];

const codexPlugins: ListGroup[] = [
  {
    title: "Our plugins · agent-tooling",
    items: [
      "personal",
      "developer-workflows",
      "mobile-development",
      "pumpd-workflows",
      "cyrus-workflows",
      "wet-in-seattle",
    ],
  },
  {
    title: "OpenAI runtime",
    items: [
      "documents",
      "pdf",
      "spreadsheets",
      "presentations",
      "template-creator",
      "sites",
      "browser",
      "chrome",
      "visualize",
    ],
  },
  {
    title: "OpenAI curated",
    items: [
      "linear",
      "vercel",
      "github",
      "sentry",
      "build-ios-apps",
      "expo",
      "supabase",
    ],
  },
];

const codexMcps: ListGroup[] = [
  {
    title: "From our plugins",
    items: ["analytics-mcp", "ios-simulator-mcp", "heroui-native", "heroui-native-pro"],
  },
  {
    title: "Runtime / vendor",
    items: ["node_repl", "sites-design-picker", "xcodebuildmcp", "github", "linear"],
  },
  {
    title: "Direct user configuration",
    items: ["figma", "heroui-pro · retained legacy exception", "computer-use · disabled"],
  },
  {
    title: "PUMPD project",
    items: ["context7", "playwright"],
  },
];

const claudeVendorSkills: ListGroup[] = [
  { title: "Anthropic", items: ["skill-creator", "frontend-design"] },
  {
    title: "Supabase",
    items: ["supabase", "supabase-postgres-best-practices"],
  },
  {
    title: "Sentry · 10 skills",
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
  {
    title: "Callstack · 14 skills",
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
  {
    title: "Shopify · 20 skills",
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
];

const codexRuntimeSkills: ListGroup[] = [
  {
    title: "OpenAI runtime · 11 skills",
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
  {
    title: "GitHub · 4 skills",
    items: ["github", "gh-address-comments", "gh-fix-ci", "yeet"],
  },
  {
    title: "Apple · 9 skills",
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
  {
    title: "Expo · 13 skills",
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
  {
    title: "Supabase · 2 skills",
    items: ["supabase", "supabase-postgres-best-practices"],
  },
  {
    title: "Other curated",
    items: ["linear", "sentry"],
  },
  {
    title: "Vercel · 47 skills",
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
];

function ItemList({ items }: { items: string[] }) {
  return (
    <ul className="item-list">
      {items.map((item) => (
        <li key={item}>{item}</li>
      ))}
    </ul>
  );
}

function Groups({ groups }: { groups: ListGroup[] }) {
  return (
    <div className="groups">
      {groups.map((group) => (
        <section className="group" key={group.title}>
          <h4>{group.title}</h4>
          {group.note ? <p>{group.note}</p> : null}
          <ItemList items={group.items} />
        </section>
      ))}
    </div>
  );
}

function ExpandableGroups({ groups }: { groups: ListGroup[] }) {
  return (
    <div className="expandable-groups">
      {groups.map((group) => (
        <details key={group.title}>
          <summary>{group.title}</summary>
          <ItemList items={group.items} />
        </details>
      ))}
    </div>
  );
}

function ClientCard({
  name,
  className,
  plugins,
  mcps,
  standaloneSkills,
  vendorSkills,
}: {
  name: string;
  className: string;
  plugins: ListGroup[];
  mcps: ListGroup[];
  standaloneSkills: string[];
  vendorSkills: ListGroup[];
}) {
  return (
    <article className={`client-card ${className}`}>
      <header className="client-header">
        <span className="client-dot" aria-hidden="true" />
        <h2>{name}</h2>
      </header>

      <section className="capability">
        <h3>Plugins</h3>
        <Groups groups={plugins} />
      </section>

      <section className="capability">
        <h3>Skills</h3>
        <div className="group owned-group">
          <h4>Our skills · agent-tooling · {ownedSkills.length}</h4>
          <ItemList items={ownedSkills} />
        </div>
        <div className="group">
          <h4>{name === "Codex" ? "Standalone · 2" : "Standalone"}</h4>
          <ItemList items={standaloneSkills} />
        </div>
        <h4 className="vendor-heading">Official and vendor skills</h4>
        <ExpandableGroups groups={vendorSkills} />
      </section>

      <section className="capability">
        <h3>MCPs</h3>
        <Groups groups={mcps} />
      </section>
    </article>
  );
}

export default function Home() {
  return (
    <main>
      <header className="page-header">
        <p className="eyebrow">CURRENT STATE · VERIFIED JULY 17, 2026</p>
        <h1>My Claude &amp; Codex Tooling</h1>
        <p className="lede">
          One page. Two clients. Every installed plugin, skill, and MCP grouped by where it comes from.
        </p>
        <p className="scope-note">
          Claude.ai and ChatGPT hosted apps/connectors are account-managed and are not included here.
        </p>
      </header>

      <div className="client-grid">
        <ClientCard
          name="Claude Code"
          className="claude"
          plugins={claudePlugins}
          mcps={claudeMcps}
          standaloneSkills={["None — ~/.claude/skills is clean"]}
          vendorSkills={claudeVendorSkills}
        />
        <ClientCard
          name="Codex"
          className="codex"
          plugins={codexPlugins}
          mcps={codexMcps}
          standaloneSkills={["chronicle", "figma"]}
          vendorSkills={codexRuntimeSkills}
        />
      </div>

      <aside className="worktree-warning">
        <div>
          <p className="warning-label">PUMPD WORKTREE-ONLY</p>
          <h2>These nine skills still exist, but they are not global.</h2>
          <p>
            They live in the hidden Codex worktree below. The Claude entries are symlinks to the same canonical files.
          </p>
          <code>/Users/arendalloul/.codex/worktrees/2ed0/pumpd-mobile-app/.agents/skills</code>
        </div>
        <ItemList items={pumpdWorktreeSkills} />
      </aside>
    </main>
  );
}
