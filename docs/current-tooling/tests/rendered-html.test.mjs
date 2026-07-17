import assert from "node:assert/strict";
import test from "node:test";

async function render() {
  const workerUrl = new URL("../dist/server/index.js", import.meta.url);
  workerUrl.searchParams.set("test", `${process.pid}-${Date.now()}`);
  const { default: worker } = await import(workerUrl.href);

  return worker.fetch(
    new Request("http://localhost/", { headers: { accept: "text/html" } }),
    { ASSETS: { fetch: async () => new Response("Not found", { status: 404 }) } },
    { waitUntil() {}, passThroughOnException() {} },
  );
}

test("renders the Claude and Codex inventory", async () => {
  const response = await render();
  assert.equal(response.status, 200);
  assert.match(response.headers.get("content-type") ?? "", /^text\/html\b/i);

  const html = await response.text();
  assert.match(html, /<title>My Claude &amp; Codex Tooling<\/title>/i);
  assert.match(html, /Claude Code/);
  assert.match(html, />Codex</);
  assert.match(html, /developer-workflows/);
  assert.match(html, /analytics-mcp/);
  assert.match(html, /Different setup/);
  assert.match(html, /Claude only/);
  assert.match(html, /Codex only/);
  assert.match(html, /PUMPD project skills/);
  assert.match(html, /backend-review/);
  assert.doesNotMatch(html, /Your site is taking shape|react-loading-skeleton/);
});
