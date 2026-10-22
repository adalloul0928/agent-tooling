# Next ESLint root directory compatibility

`@next/eslint-plugin-next@16.4.2` uses `fast-glob@3.3.1` only for the
`globSync(pattern, { onlyDirectories: true })` call in its root directory
lookup. That dependency brings in `micromatch` and `braces`;
[GHSA-vfj7-8cjw-p6xm](https://github.com/advisories/GHSA-vfj7-8cjw-p6xm)
has no patched `braces` release.

The site overrides only that plugin's `fast-glob` dependency with this local
package, backed by patched `glob@13.0.6`. It keeps Next's lint rules enabled,
including `no-html-link-for-pages` with explicit `settings.next.rootDir`.
It exposes the one named export the plugin uses and preserves fast-glob's
nonempty string/array validation. An empty array remains valid.

Literal root directories resolve to themselves. The wrapper retains literal
path spelling and absolute/relative glob results, includes only directories,
excludes implicit dot-directory matches, matches case sensitively, follows
directory symlinks, and skips missing or broken links while propagating other
filesystem errors. Dynamic patterns retain fast-glob's traversal-base
exclusions, including brace-expanded patterns and globstars. `glob` was chosen
because it preserves symlink entries for directory filtering; the evaluated
tinyglobby/fdir backend omitted them. Its `minimatch` dependency uses patched
`brace-expansion` releases instead of the vulnerable `braces` package.
Next processes a configured root array as individual string calls.
Dynamic detection follows fast-glob's published default rules, including
singleton character classes. Within a dynamic brace-expanded branch, balanced
bare parenthesized groups use equivalent `@(...)` syntax for node-glob;
character classes, escaped parentheses, and existing extglob operators retain
their syntax. Static branches retain their literal path spelling.
Every candidate, including a static path, also passes the original
`picomatch@2.3.2` positive regex filter, which has no dependencies. This preserves fast-glob's final
matching behavior for bare parentheses even when a literal directory exists.
The project `.npmrc` sets `install-links=true` so npm packs the local package
and consistently installs the override during `npm ci`. The synchronous ES
module export is supported by the site's Node 22.13+ requirement. Refresh the
lockfile with npm 11; npm 10 can silently retain the original registry package
when updating this scoped file override. Clean `npm ci` is supported on both,
and the tests assert the identity of the adapter loaded by the installed plugin.

The tests exercise the installed Next plugin and routes in `pages`/`src/pages`,
default/literal/array/glob/brace roots, missing and invalid settings, input
validation, and bounded deeply nested patterns. Remove the override, direct
development dependency, package, and tests once an upstream plugin release
removes this vulnerable dependency tree.
