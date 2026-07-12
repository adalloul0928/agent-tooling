import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

async function render() {
  const workerUrl = new URL("../dist/server/index.js", import.meta.url);
  workerUrl.searchParams.set("test", `${process.pid}-${Date.now()}`);
  const { default: worker } = await import(workerUrl.href);

  return worker.fetch(
    new Request("http://localhost/", {
      headers: { accept: "text/html" },
    }),
    {
      ASSETS: {
        fetch: async () => new Response("Not found", { status: 404 }),
      },
    },
    {
      waitUntil() {},
      passThroughOnException() {},
    },
  );
}

test("server-renders the Agent Tooling Atlas", async () => {
  const response = await render();
  assert.equal(response.status, 200);
  assert.match(response.headers.get("content-type") ?? "", /^text\/html\b/i);

  const html = await response.text();
  assert.match(html, /<title>Agent Tooling Atlas<\/title>/i);
  assert.match(html, /One source\./);
  assert.match(html, /Many surfaces\./);
  assert.match(html, /Microsoft APM/);
  assert.match(html, /Claude and Codex are families of products/);
  assert.match(html, /What happens when I add/);
  assert.match(html, /Who owns what/);
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
  assert.match(page, /prefers-reduced-motion|StatusPill/);
  assert.match(css, /prefers-reduced-motion:\s*reduce/);
  assert.match(layout, /title:\s*"Agent Tooling Atlas"/);
  assert.doesNotMatch(page, /_sites-preview|SkeletonPreview/);
  assert.doesNotMatch(packageJson, /react-loading-skeleton/);
  assert.doesNotMatch(css, /data:image\/svg\+xml/);
});
