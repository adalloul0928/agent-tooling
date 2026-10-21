const repository = "https://github.com/adalloul0928/agent-tooling";
const docs = `${repository}/blob/main/docs`;

const clients = [
  {
    name: "Codex",
    description: "Skills, native plugins, user-level MCP connections, and local settings.",
  },
  {
    name: "Claude Code",
    description: "Skills, native plugins, MCP connections, and scoped configuration.",
  },
  {
    name: "Gemini CLI",
    description: "Skills packaged as extensions and linked through the native CLI.",
  },
  {
    name: "Kiro CLI",
    description: "Standard skill folders and native MCP connection commands.",
  },
];

const steps = [
  {
    title: "Discover",
    detail: "See tools already installed in your clients. The first scan records what it finds without moving or installing files.",
  },
  {
    title: "Assign",
    detail: "Choose the apps or projects that should use a tool. Native plugins stay together with their bundled skills and connections.",
  },
  {
    title: "Review",
    detail: "Inspect conflicts, removals, or changes to existing configuration. Unsupported operations stay visible for manual review.",
  },
  {
    title: "Install",
    detail: "Apply supported changes through the client’s native commands or managed folders. Keep a receipt and rollback record.",
  },
];

export default function Home() {
  return (
    <>
      <a className="skip-link" href="#main">Skip to content</a>
      <header className="site-header">
        <a className="wordmark" href="#">Agent Tooling</a>
        <nav aria-label="Main navigation">
          <a href="#features">Features</a>
          <a href="#privacy">Your data</a>
          <a href={`${docs}/README.md`}>Documentation</a>
          <a href={repository}>GitHub</a>
        </nav>
      </header>

      <main id="main">
        <section className="hero" aria-labelledby="title">
          <p className="eyebrow">Native macOS app · Apple Silicon · macOS 26+</p>
          <h1 id="title">Your agent tools,<br />in one library.</h1>
          <p className="lead">
            Manage skills, plugins, and MCP connections across Codex, Claude Code,
            Gemini CLI, and Kiro CLI. Choose where each tool belongs and review
            changes to your setup.
          </p>
          <div className="actions">
            <a className="button" href={`${repository}/releases`}>View releases</a>
            <a className="button secondary" href={`${repository}#build-from-source`}>Build from source</a>
          </div>
          <p className="release-note">
            The first public DMG has not been published yet. Source builds are available now.
          </p>
        </section>

        <section id="features" aria-labelledby="features-title">
          <div className="section-heading">
            <p className="eyebrow">Library to installation</p>
            <h2 id="features-title">See what changes before it changes.</h2>
          </div>
          <ol className="steps">
            {steps.map((step, index) => (
              <li key={step.title}>
                <span className="step-number" aria-hidden="true">0{index + 1}</span>
                <h3>{step.title}</h3>
                <p>{step.detail}</p>
              </li>
            ))}
          </ol>
          <div className="feature-notes">
            <article>
              <h3>Keep tools current</h3>
              <p>
                Follow repository sources and check for updates. Choose automatic
                installation or review by tool type; modified copies wait for a decision.
              </p>
            </article>
            <article>
              <h3>Use another Mac</h3>
              <p>
                Optionally sync through a Git repository you control. Each Mac keeps
                its own installation state and applies its own changes.
              </p>
            </article>
            <article>
              <h3>Maintain your setup</h3>
              <p>
                Inspect configuration, review proposed fixes, and create skills with
                an installed Claude Code or Codex client.
              </p>
            </article>
          </div>
        </section>

        <section aria-labelledby="clients-title">
          <div className="section-heading">
            <p className="eyebrow">Supported clients</p>
            <h2 id="clients-title">Native formats and installation paths.</h2>
          </div>
          <div className="client-grid">
            {clients.map((client) => (
              <article className="client-card" key={client.name}>
                <h3>{client.name}</h3>
                <p>{client.description}</p>
              </article>
            ))}
          </div>
          <p className="support-note">
            Install and sign in to clients separately. Support depends on their
            installed versions; an installation does not confirm authentication.
            See the <a href={`${docs}/compatibility.md`}>compatibility notes</a>.
          </p>
        </section>

        <section id="privacy" className="privacy" aria-labelledby="privacy-title">
          <div>
            <p className="eyebrow">Your data</p>
            <h2 id="privacy-title">A local workspace.<br />Optional online features.</h2>
          </div>
          <div className="privacy-copy">
            <p>
              Agent Tooling keeps its workspace in your Mac’s Application Support
              folder. Local use requires no GitHub account or sync repository.
              Credentials remain with their owning client, account, or keychain.
            </p>
            <p>
              Catalog discovery, updates, sync, and assistant requests contact the
              services you choose. Assistant features use your installed client’s
              account and permissions.
            </p>
            <a href={`${repository}/blob/main/apps/agent-tooling-macos/README.md`}>Read the app guide →</a>
          </div>
        </section>
      </main>

      <footer>
        <p>Agent Tooling</p>
        <div>
          <a href={`${repository}/issues`}>Report an issue</a>
          <a href={`${docs}/third-party-reuse-2026-09.md`}>Third-party components</a>
          <a href={`${docs}/macos-app-release.md`}>Release guide</a>
        </div>
      </footer>
    </>
  );
}
