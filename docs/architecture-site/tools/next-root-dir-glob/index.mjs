import fs from "node:fs";
import path from "node:path";
import { Glob } from "glob";
import globParent from "glob-parent";
import picomatch from "picomatch";

const defaults = { dot: false, follow: true, nocase: false, mark: false, realpath: false };
const matchOptions = {
  dot: false,
  matchBase: false,
  nobrace: false,
  nocase: false,
  noext: false,
  noglobstar: false,
  posix: true,
  strictSlashes: false,
};
const missing = (error) => error.code === "ENOENT";

// fast-glob 3.3.1 treats singleton character classes and regex-style groups as
// dynamic even when minimatch can optimize them into a literal string.
function isDynamicPattern(pattern) {
  const openingBrace = pattern.indexOf("{");
  const closingBrace = pattern.indexOf("}", openingBrace + 1);
  return pattern.includes("\\")
    || /[*?]|^!/.test(pattern)
    || /\[[^[]*]/.test(pattern)
    || /(?:^|[^!*+?@])\([^(]*\|[^|]*\)/.test(pattern)
    || /[!*+?@]\([^(]*\)/.test(pattern)
    || (openingBrace !== -1 && closingBrace !== -1 && /,|\.\./.test(pattern.slice(openingBrace, closingBrace)));
}

function normalizeGroups(pattern) {
  if (!isDynamicPattern(pattern)) return pattern;
  const groups = [];
  const prefixes = new Set();
  const escaped = new Set();
  for (let index = 0; index < pattern.length; index += 1) {
    const character = pattern[index];
    if (character === "\\") {
      escaped.add(index + 1);
      index += 1;
    } else if (character === "[") {
      let end = index + 1;
      if (pattern[end] === "!" || pattern[end] === "^") end += 1;
      if (pattern[end] === "]") end += 1;
      for (; end < pattern.length; end += 1) {
        if (pattern[end] === "\\") end += 1;
        else if (pattern[end] === "[" && pattern[end + 1] === ":") {
          const posixEnd = pattern.indexOf(":]", end + 2);
          if (posixEnd !== -1) end = posixEnd + 1;
        } else if (pattern[end] === "]") break;
      }
      if (end < pattern.length) index = end;
    } else if (character === "(") {
      const extglob = /[!*+?@]/.test(pattern[index - 1] ?? "") && !escaped.has(index - 1);
      groups.push({ index, extglob });
    } else if (character === ")") {
      const opening = groups.pop();
      if (opening && !opening.extglob) prefixes.add(opening.index);
    }
  }
  // In a dynamic fast-glob pattern, bare parentheses form regex groups. The
  // equivalent node-glob syntax is @(...); keep static/escaped/class text intact.
  return pattern.split("").map((character, index) => prefixes.has(index) ? `@${character}` : character).join("");
}

function isDirectory(entry) {
  try {
    return fs.statSync(entry).isDirectory();
  } catch (error) {
    if (missing(error)) return false;
    throw error;
  }
}

// Next only calls globSync(root, { onlyDirectories: true }) for rootDir lookup.
// Keep that narrow contract, including fast-glob's pattern input validation.
export function globSync(patterns) {
  const values = Array.isArray(patterns) ? patterns : [patterns];
  if (!values.every((pattern) => typeof pattern === "string" && pattern.length > 0)) {
    throw new TypeError("Patterns must be a string (non empty) or an array of strings");
  }
  const matches = values.flatMap((pattern) => {
    // fast-glob applies this regex to stat results too. In particular, bare
    // parentheses must not become accepted simply because a literal path exists.
    const positive = picomatch.makeRe(pattern, matchOptions);
    const matchesPositive = (entry) => {
      const filepath = entry.startsWith("./") ? entry.slice(2) : entry;
      return positive.test(filepath) || positive.test(`${filepath}/`);
    };
    let scanError;
    // glob ignores some filesystem errors internally; fast-glob propagates
    // access/IO errors. Record those errors while keeping glob's normal walk.
    const scanFs = Object.fromEntries(
      ["lstatSync", "readdirSync", "readlinkSync", "realpathSync"].map((method) => [method, (...args) => {
        try {
          return fs[method](...args);
        } catch (error) {
          if (!missing(error)) scanError ??= error;
          throw error;
        }
      }]),
    );
    const options = { ...defaults, fs: scanFs };
    const expanded = new Glob(pattern, options).patterns.map((part) => normalizeGroups(part.globString()));
    const dynamic = expanded.filter(isDynamicPattern);
    const mergeInside = dynamic.some((part) => !part.startsWith("../") && globParent(part, { flipBackslashes: false }) === ".");
    const groups = new Map();
    for (const part of expanded) {
      const literal = !isDynamicPattern(part);
      const base = !literal && mergeInside && !part.startsWith("../") ? "." : globParent(part, { flipBackslashes: false });
      const key = `${literal ? "literal" : "dynamic"}:${base}`;
      const group = groups.get(key) ?? { literal, base, patterns: [] };
      group.patterns.push(part);
      groups.set(key, group);
    }
    return [...groups.values()].flatMap((group) => {
      if (group.literal) return group.patterns.filter(isDirectory);
      // fast-glob scans each dynamic task base and surfaces ENOTDIR when it
      // points to a file. glob would otherwise silently skip that traversal.
      try {
        if (!fs.statSync(group.base).isDirectory()) fs.readdirSync(group.base);
      } catch (error) {
        if (missing(error)) return [];
        throw error;
      }
      const entries = new Glob(group.patterns, options).walkSync();
      if (scanError) throw scanError;
      return entries
        // fast-glob walks children of each dynamic task base, excluding the
        // base itself. Resolve lexically so symlink aliases stay distinct.
        .filter((entry) => path.resolve(entry) !== path.resolve(group.base))
        .filter(isDirectory)
        .map((entry) => pattern.endsWith("/") && !entry.endsWith("/") ? `${entry}/` : entry);
    }).filter(matchesPositive);
  });
  return [...new Set(matches)];
}
