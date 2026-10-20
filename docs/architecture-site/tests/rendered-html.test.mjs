import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

async function render() {
  return readFile(new URL("../out/index.html", import.meta.url), "utf8");
}

test("exports the public app guide with accurate installation links", async () => {
  const html = await render();
  assert.match(html, /<title>Agent Tooling/);
  for (const client of ["Codex", "Claude Code", "Gemini CLI", "Kiro CLI"]) {
    assert.ok(html.includes(client), `Missing supported client: ${client}`);
  }
  assert.match(html, /first public DMG has not been published yet/);
  assert.match(html, /href="https:\/\/github\.com\/adalloul0928\/agent-tooling\/releases"/);
  assert.match(html, /href="https:\/\/github\.com\/adalloul0928\/agent-tooling#build-from-source"/);
  assert.match(html, /Apple Silicon/);
  assert.match(html, /macOS 26/);
});

test("provides accessible navigation and documents optional network use", async () => {
  const html = await render();
  assert.match(html, /href="#main">Skip to content/);
  assert.match(html, /<main id="main"/);
  assert.match(html, /aria-label="Main navigation"/);
  assert.match(html, /id="privacy"/);
  assert.match(html, /services you choose/);
  assert.match(html, /Credentials remain with their owning client/);
  assert.doesNotMatch(html, /fonts\.googleapis\.com|fonts\.gstatic\.com/);
});
