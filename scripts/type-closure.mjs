#!/usr/bin/env node
// What a type actually depends on.
//
// Answers one question before a refactor: if this type were to move, what has
// to move with it, and how much of that is stuck in a file that needs a
// platform import. Written while lifting ParleyCore's domain vocabulary out of
// the files that implement it, where guessing produced the wrong answer twice.
//
// It follows stored properties and enum associated values only. An earlier
// version followed every capitalised identifier inside a declaration and
// reported RelayHandoff as depending on ManagedWorktreeService, which it
// cannot: that over-reported the closure by more than double and would have
// sequenced the work wrongly.
//
// This is a regex reading of Swift, not a compiler. It cannot see conditional
// conformances, generic constraints or types named only inside function
// bodies. Treat a small closure as worth verifying and a large one as a
// reason to look closer, never as proof.
//
//   node scripts/type-closure.mjs RelayHandoff
//   node scripts/type-closure.mjs WorkbenchPane --dir native/Sources/ParleyCore

import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";

export const PLATFORM_FRAMEWORKS = ["Darwin", "CryptoKit", "Security", "ImageIO", "CoreGraphics"];
const DECLARATION = /^(?:public |internal )?(?:final )?(?:struct|enum|class|actor|protocol) ([A-Z]\w*)/;

export function index(directory, list = readdirSync, read = readFileSync) {
  const declaredIn = {}, body = {}, platform = new Set();
  for (const file of list(directory).filter((f) => f.endsWith(".swift")).sort()) {
    const source = read(join(directory, file), "utf8");
    if (PLATFORM_FRAMEWORKS.some((m) => new RegExp(`^import ${m}\\s*$`, "m").test(source))) platform.add(file);
    const lines = source.split("\n");
    for (let i = 0; i < lines.length; i++) {
      const match = lines[i].match(DECLARATION);
      if (!match) continue;
      const name = match[1];
      if (declaredIn[name]) continue;            // first declaration wins
      declaredIn[name] = file;
      let depth = 0, started = false, collected = [];
      for (let j = i; j < lines.length; j++) {
        for (const character of lines[j]) {
          if (character === "{") { depth++; started = true; } else if (character === "}") depth--;
        }
        if (j > i) collected.push(lines[j]);
        if (started && depth <= 0) break;
      }
      body[name] = collected.join("\n");
    }
  }
  return { declaredIn, body, platform };
}

export function references(name, { declaredIn, body }) {
  const found = new Set();
  const text = body[name] ?? "";
  const take = (fragment) => {
    for (const token of fragment.matchAll(/\b([A-Z]\w+)\b/g)) {
      if (declaredIn[token[1]] && token[1] !== name) found.add(token[1]);
    }
  };
  for (const property of text.matchAll(/^\s*(?:public |private |internal )?(?:let|var)\s+\w+\s*:\s*([^={\n]+)/gm)) take(property[1]);
  for (const associated of text.matchAll(/^\s*case\s+\w+\(([^)]*)\)/gm)) take(associated[1]);
  return found;
}

export function closure(root, model) {
  if (!model.declaredIn[root]) throw new Error(`no declaration found for ${root}`);
  const seen = new Set([root]), queue = [root];
  while (queue.length > 0) {
    for (const reference of references(queue.pop(), model)) {
      if (!seen.has(reference)) { seen.add(reference); queue.push(reference); }
    }
  }
  return seen;
}

export function group(types, { declaredIn, platform }) {
  const byFile = {};
  for (const type of types) (byFile[declaredIn[type] ?? "(unknown)"] ??= []).push(type);
  return Object.entries(byFile)
    .map(([file, names]) => ({ file, names: names.sort(), platform: platform.has(file) }))
    .sort((a, b) => b.names.length - a.names.length || a.file.localeCompare(b.file));
}

function main() {
  const [root, ...rest] = process.argv.slice(2);
  if (!root) {
    console.error("usage: node scripts/type-closure.mjs <TypeName> [--dir <path>]");
    process.exit(2);
  }
  const directory = rest.includes("--dir") ? rest[rest.indexOf("--dir") + 1] : "native/Sources/ParleyCore";
  const model = index(directory);
  let types;
  try { types = closure(root, model); } catch (error) { console.error(String(error.message)); process.exit(1); }
  const groups = group(types, model);
  const stuck = groups.filter((g) => g.platform).reduce((n, g) => n + g.names.length, 0);
  console.log(`${root}: ${types.size} types across ${groups.length} files, ${stuck} in platform-importing files\n`);
  for (const { file, names, platform } of groups) {
    console.log(`  ${platform ? "[PLATFORM]" : "[pure]    "} ${file.padEnd(34)} ${names.join(", ")}`);
  }
  if (stuck === 0) console.log(`\n${root} can be read without any platform import.`);
}

if (import.meta.url === `file://${process.argv[1]}`) main();
