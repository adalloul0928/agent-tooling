import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import { mkdtemp, mkdir, rm, symlink, writeFile } from "node:fs/promises";
import { createRequire } from "node:module";
import { tmpdir } from "node:os";
import path from "node:path";
import { after, before, test } from "node:test";
import { fileURLToPath } from "node:url";
import { Linter } from "eslint";
import nextPlugin from "@next/eslint-plugin-next";

// Resolve from the installed plugin so these tests cover npm's override too.
const require = createRequire(import.meta.url);
const nextRequire = createRequire(require.resolve("@next/eslint-plugin-next"));
const globModule = nextRequire.resolve("fast-glob");
const { globSync } = nextRequire("fast-glob");
const { getRootDirs } = nextRequire("./utils/get-root-dirs");
let fixture;
let alpha;
let beta;

before(async () => {
  fixture = await mkdtemp(path.join(tmpdir(), "next-root-dir-glob-"));
  alpha = path.join(fixture, "apps", "alpha");
  beta = path.join(fixture, "apps", "beta");
  for (const file of [
    "pages/about.tsx",
    "apps/alpha/pages/alpha.tsx",
    "apps/alpha/nested/pages/hidden.tsx",
    "apps/beta/src/app/beta/page.tsx",
    "apps/beta/src/pages/beta.tsx",
    "apps/.hidden/pages/secret.tsx",
    "special/literal(alpha)/pages/paren.tsx",
    "special/(alpha|beta)/pages/pipe.tsx",
    "special/[alpha]/pages/bracket.tsx",
  ]) {
    const filename = path.join(fixture, file);
    await mkdir(path.dirname(filename), { recursive: true });
    await writeFile(filename, "export default function Page() { return null; }\n");
  }
  await symlink(alpha, path.join(fixture, "linked-alpha"), "dir");
  await symlink(path.join(fixture, "absent"), path.join(fixture, "linked-broken"), "dir");
});

after(async () => {
  await rm(fixture, { recursive: true, force: true });
});

function roots(rootDir) {
  return getRootDirs({ cwd: fixture, settings: { next: { rootDir } } });
}

function lintLinks(rootDir, hrefs) {
  const linter = new Linter({ cwd: fixture });
  const source = `const Example = () => <>${hrefs.map((href) => `<a href="${href}">Visit</a>`).join("")}</>;`;
  return linter.verify(source, {
    languageOptions: {
      ecmaVersion: 2022,
      sourceType: "module",
      parserOptions: { ecmaFeatures: { jsx: true } },
    },
    plugins: { "@next/next": nextPlugin },
    rules: { "@next/next/no-html-link-for-pages": "error" },
    settings: { next: { rootDir } },
  });
}

function assertInternalLinks(rootDir, hrefs) {
  const messages = lintLinks(rootDir, hrefs);
  assert.equal(messages.length, hrefs.length);
  for (const [index, message] of messages.entries()) {
    assert.equal(message.ruleId, "@next/next/no-html-link-for-pages");
    assert.match(message.message, /Use `<Link \/>`/);
    assert.ok(message.message.includes(`\`${hrefs[index]}/\``));
  }
}

test("the installed Next plugin loads the local root-directory adapter", () => {
  const metadata = JSON.parse(fs.readFileSync(path.join(path.dirname(globModule), "package.json"), "utf8"));
  assert.equal(metadata.name, "@agent-tooling/next-root-dir-glob");
});

test("the Next link rule finds pages with its default root", () => {
  assert.deepEqual(roots(undefined), [fixture]);
  assertInternalLinks(undefined, ["/about"]);
});

test("a literal root selects that directory, without expanding its children", () => {
  assert.deepEqual(roots(alpha), [alpha]);
  assert.deepEqual(globSync(alpha, { onlyDirectories: true }), [alpha]);
  assertInternalLinks(alpha, ["/alpha"]);
  assert.deepEqual(lintLinks(alpha, ["/hidden", "https://example.com/alpha"]), []);
});

test("literal roots preserve '/', a relative './' prefix, and directory suffixes", () => {
  const relative = `./${path.relative(process.cwd(), alpha)}`;
  for (const root of [relative, `${alpha}/`]) {
    assert.deepEqual(roots(root), [root]);
    assertInternalLinks(root, ["/alpha"]);
  }
  assert.deepEqual(globSync("/", { onlyDirectories: true }), ["/"]);
});

test("the Next link rule finds pages and src/pages routes from a root array", () => {
  assert.deepEqual(roots([alpha, beta]), [alpha, beta]);
  assertInternalLinks([alpha, beta], ["/alpha", "/beta"]);
  assert.deepEqual(roots([alpha, alpha]), [alpha, alpha]);
  assertInternalLinks([alpha, alpha], ["/alpha"]);
});

test("root globs and brace alternatives keep the Next link rule active", () => {
  for (const root of [
    path.join(fixture, "apps", "*"),
    path.join(fixture, "apps", "{alpha,beta}"),
  ]) {
    assert.deepEqual(roots(root).sort(), [alpha, beta].sort());
    assertInternalLinks(root, ["/alpha", "/beta"]);
  }
});

test("root globs match case sensitively on every platform", () => {
  assert.deepEqual(roots(path.join(fixture, "apps", "ALP*")), []);
  assert.deepEqual(roots(path.join(fixture, "apps", "alp*")), [alpha]);
});

test("singleton character classes keep the installed Next link rule active", () => {
  for (const name of ["[a]lpha", "alph[a]"]) {
    const root = path.join(fixture, "apps", name);
    assert.deepEqual(roots(root), [alpha]);
    assertInternalLinks(root, ["/alpha"]);
  }
});

test("bare and nested parenthesized groups keep the installed Next link rule active", () => {
  for (const name of ["(alpha|beta)", "((alpha|beta))"]) {
    const root = path.join(fixture, "apps", name);
    assert.deepEqual(roots(root).sort(), [alpha, beta].sort());
    assertInternalLinks(root, ["/alpha", "/beta"]);
  }
  const root = path.join(fixture, "app*", "(alpha)");
  assert.deepEqual(roots(root), [alpha]);
  assertInternalLinks(root, ["/alpha"]);
});

test("existing extglobs retain their operators and matching behavior", () => {
  for (const group of ["@(alpha|beta)", "+(alpha|beta)", "?(alpha|beta)", "*(alpha|beta)", "!(absent|missing)"]) {
    const root = path.join(fixture, "apps", group);
    assert.deepEqual(roots(root).sort(), [alpha, beta].sort());
    assertInternalLinks(root, ["/alpha", "/beta"]);
  }
});

test("static parenthesis paths retain the original final regex filter", (t) => {
  t.mock.method(console, "warn", () => {});
  const literal = path.join(fixture, "special", "literal(alpha)");
  for (const root of [literal, path.join(fixture, "special", "{literal(alpha),absent}")]) {
    assert.deepEqual(roots(root), []);
    assert.deepEqual(lintLinks(root, ["/paren"]), []);
  }
  assertInternalLinks(path.join(fixture, "special", "literal[(]alpha[)]"), ["/paren"]);
  assertInternalLinks(path.join(fixture, "special", "[(]alpha[|]beta[)]"), ["/pipe"]);
  assertInternalLinks(path.join(fixture, "special", "[[]alpha]"), ["/bracket"]);
  // Next converts backslashes to path separators before the adapter call;
  // exercise its exported globSync directly for escaped-pattern compatibility.
  assert.deepEqual(globSync(path.join(fixture, "special", String.raw`\(alpha\|beta\)`), { onlyDirectories: true }), [path.join(fixture, "special", "(alpha|beta)")]);
});

test("globstar roots exclude each task base while keeping matching child roots", () => {
  const originalCwd = process.cwd();
  process.chdir(fixture);
  try {
    const cwd = process.cwd();
    const resolved = (pattern) => roots(pattern).map((entry) => path.resolve(entry));
    assert.ok(!resolved("**").includes(cwd));
    assert.ok(!resolved("apps/**").includes(path.join(cwd, "apps")));
    assert.ok(resolved("**/apps/**").includes(path.join(cwd, "apps")));
    const braced = resolved("{apps,linked-alpha}/**");
    assert.ok(!braced.includes(path.join(cwd, "apps")));
    assert.ok(!braced.includes(path.join(cwd, "linked-alpha")));
    assert.ok(braced.includes(path.join(cwd, "apps", "alpha")));
    assert.ok(resolved("{apps/**,**/absent/**}").includes(path.join(cwd, "apps")));
    assert.deepEqual(lintLinks("**", ["/about"]), []);
  } finally {
    process.chdir(originalCwd);
  }
});

test("root lookup keeps default hidden-directory and symlink behavior", () => {
  const hidden = path.join(fixture, "apps", ".hidden");
  const linked = path.join(fixture, "linked-alpha");
  assertInternalLinks(hidden, ["/secret"]);
  for (const root of [linked, path.join(fixture, "linked-*")]) {
    assert.deepEqual(roots(root), [linked]);
    assertInternalLinks(root, ["/alpha"]);
  }
  assert.deepEqual(lintLinks(path.join(fixture, "apps", "*"), ["/secret"]), []);
  assert.deepEqual(roots(path.join(fixture, "linked-broken")), []);
});

test("unexpected directory stat errors propagate instead of skipping lint", (t) => {
  t.mock.method(fs, "statSync", () => {
    throw Object.assign(new Error("permission denied"), { code: "EACCES" });
  });
  assert.throws(() => roots(alpha), { code: "EACCES" });
});

test("unexpected scan errors propagate instead of silently disabling lint", (t) => {
  t.mock.method(fs, "readdirSync", () => {
    throw Object.assign(new Error("permission denied"), { code: "EACCES" });
  });
  assert.throws(() => roots(path.join(fixture, "apps", "*")), { code: "EACCES" });
});

test("file-as-directory traversal preserves ENOTDIR errors", () => {
  const file = path.join(fixture, "pages", "about.tsx");
  for (const pattern of [`${file}/*`, `${file}/**`, `${file}/nested`]) {
    assert.throws(() => roots(pattern), { code: "ENOTDIR" });
  }
});

test("missing roots and an empty root array do not create routes", (t) => {
  t.mock.method(console, "warn", () => {});
  for (const root of [path.join(fixture, "absent"), path.join(fixture, "pages", "about.tsx"), []]) {
    assert.deepEqual(roots(root), []);
    assert.deepEqual(lintLinks(root, ["/about", "/alpha"]), []);
  }
  assert.deepEqual(globSync([], { onlyDirectories: true }), []);
});

test("invalid root settings preserve the plugin's fallback and filtering", (t) => {
  t.mock.method(console, "warn", () => {});
  for (const root of [null, false, 12, {}]) {
    assert.deepEqual(roots(root), [fixture]);
    assertInternalLinks(root, ["/about"]);
  }
  assert.deepEqual(roots([null, 12, {}, alpha]), [alpha]);
  assertInternalLinks([null, 12, {}, alpha], ["/alpha"]);
  assert.deepEqual(roots([null, 12, {}]), []);
  assert.deepEqual(lintLinks([null, 12, {}], ["/about"]), []);
});

test("empty string roots still fail with TypeError instead of silently skipping lint", () => {
  for (const root of ["", [alpha, ""]]) {
    assert.throws(() => roots(root), TypeError);
    assert.throws(() => lintLinks(root, ["/alpha"]), TypeError);
  }
});

test("the compatibility export validates nonempty string patterns", () => {
  for (const pattern of ["", [""], [alpha, 12], null, undefined, 12, {}]) {
    assert.throws(() => globSync(pattern, { onlyDirectories: true }), TypeError);
  }
  assert.deepEqual(globSync([alpha, beta], { onlyDirectories: true }).sort(), [alpha, beta].sort());
});

test("deep nested brace patterns finish within a bounded child process", () => {
  // GHSA-vfj7-8cjw-p6xm concerns deep brace nesting. Cover both nested
  // alternatives and nested ranges without letting a parser regression hang CI.
  const patterns = [
    `${"{a,".repeat(2000)}b${"}".repeat(2000)}`,
    `${"{1..3,".repeat(2000)}x${"}".repeat(2000)}`,
  ];
  for (const pattern of patterns) {
    const child = spawnSync(process.execPath, [
      "--max-old-space-size=128",
      "--input-type=module",
      "-e",
      `import assert from "node:assert/strict";
       import { createRequire } from "node:module";
       const require = createRequire(import.meta.url);
       const { globSync } = require(${JSON.stringify(globModule)});
       assert.deepEqual(globSync(${JSON.stringify(path.join(fixture, pattern))}, { onlyDirectories: true }), []);`,
    ], {
      cwd: fileURLToPath(new URL("..", import.meta.url)),
      encoding: "utf8",
      timeout: 5000,
    });
    assert.ifError(child.error);
    assert.equal(child.signal, null, child.stderr);
    assert.equal(child.status, 0, child.stderr);
  }
});
