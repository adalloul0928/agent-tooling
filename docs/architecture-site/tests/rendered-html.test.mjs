import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

async function render() {
  return readFile(new URL("../out/index.html", import.meta.url), "utf8");
}

test("statically renders the Agent Tooling Atlas", async () => {
  const html = await render();
  assert.match(html, /<title>Agent Tooling Atlas<\/title>/i);
  assert.match(html, /One source\./);
  assert.match(html, /Many surfaces\./);
  assert.match(html, /Microsoft APM/);
  assert.match(html, /Claude and Codex are families of products/);
  assert.match(html, /What happens when I add/);
  assert.match(html, /Who owns what/);
  assert.match(html, /Every atom has one job/);
  assert.match(html, /Small bundles, explicit projects/);
  assert.match(html, /personal/);
  assert.match(html, /developer-workflows/);
  assert.match(html, /cyrus-workflows/);
  assert.match(html, /pumpd-workflows/);
  assert.match(html, /wet-in-seattle/);
  assert.match(html, /mobile-development/);
  assert.match(html, /Profiles answer/);
  assert.match(html, /Installed is not authenticated/);
  assert.match(html, /Useful package manager\. Optional here\./);
  assert.match(html, /apm\.lock\.yaml/);
  assert.doesNotMatch(html, /codex-preview|react-loading-skeleton/i);
});

test("keeps the guide interactive, accessible, and free of starter artifacts", async () => {
  const [page, layout, css, packageJson] = await Promise.all([
    readFile(new URL("../app/page.tsx", import.meta.url), "utf8"),
    readFile(new URL("../app/layout.tsx", import.meta.url), "utf8"),
    readFile(new URL("../app/globals.css", import.meta.url), "utf8"),
    readFile(new URL("../package.json", import.meta.url), "utf8"),
  ]);

  assert.match(page, /useState/);
  assert.match(page, /role="tablist"/);
  assert.match(page, /aria-selected/);
  assert.match(page, /aria-label="Scrollable capability ownership matrix"/);
  assert.match(page, /aria-label="Profile composition diagram"/);
  assert.match(page, /aria-label="Capability installation and authentication flow"/);
  assert.match(page, /prefers-reduced-motion|StatusPill/);
  assert.match(css, /prefers-reduced-motion:\s*reduce/);
  assert.match(layout, /title:\s*"Agent Tooling Atlas"/);
  assert.doesNotMatch(page, /_sites-preview|SkeletonPreview/);
  assert.doesNotMatch(packageJson, /react-loading-skeleton/);
  assert.doesNotMatch(css, /data:image\/svg\+xml/);
});
