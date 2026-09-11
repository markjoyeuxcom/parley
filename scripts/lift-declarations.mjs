#!/usr/bin/env node
// Move whole Swift declarations from one file to another, unchanged.
//
// The seam work in ParleyCore is mostly this: a value type declared beside the
// implementation that produces it, needing to live somewhere a caller can read
// without taking the platform with it. Doing that by hand invites losing a
// doc comment or an enum case, and these types are Codable and persisted, so a
// dropped case is a silent migration of existing records.
//
// Dry run by default. Nothing is written without --write.
//
//   node scripts/lift-declarations.mjs --from native/Sources/ParleyCore/Relay.swift \
//     --to native/Sources/ParleyCore/RelayHandoffVocabulary.swift RelayHandoff
//
// After writing, verify it really was a move rather than trusting the build:
//
//   git add -A && git diff --cached HEAD -- <dir> | ...
//
// compare removed against re-added lines. A green test suite will not notice a
// renamed enum case; that comparison will.

import { existsSync, readFileSync, writeFileSync } from "node:fs";

export function findDeclaration(lines, name) {
  const start = lines.findIndex((line) =>
    new RegExp(`^public (?:enum|struct|protocol|final class|class|actor) ${name}\\b`).test(line));
  if (start < 0) return null;
  let top = start;
  while (top > 0 && /^\s*\/\/\//.test(lines[top - 1])) top--;   // carry the doc comment
  let depth = 0, started = false, end = start;
  for (let j = start; j < lines.length; j++) {
    for (const character of lines[j]) {
      if (character === "{") { depth++; started = true; } else if (character === "}") depth--;
    }
    if (started && depth <= 0) { end = j; break; }
  }
  if (!started || depth > 0) return null;                        // unbalanced: refuse rather than guess
  return { name, top, end };
}

export function plan(source, names) {
  const lines = source.split("\n");
  const blocks = [];
  for (const name of names) {
    const found = findDeclaration(lines, name);
    if (!found) throw new Error(`could not find a complete declaration for ${name}`);
    blocks.push(found);
  }
  blocks.sort((a, b) => a.top - b.top);
  for (let i = 1; i < blocks.length; i++) {
    if (blocks[i].top <= blocks[i - 1].end) {
      throw new Error(`${blocks[i - 1].name} and ${blocks[i].name} overlap; lift them separately`);
    }
  }
  const moved = blocks.map((b) => lines.slice(b.top, b.end + 1).join("\n")).join("\n\n");
  const drop = new Set();
  for (const b of blocks) for (let i = b.top; i <= b.end; i++) drop.add(i);
  const remaining = lines.filter((_, i) => !drop.has(i)).join("\n").replace(/\n{4,}/g, "\n\n\n");
  return { blocks, moved, remaining };
}

function main() {
  const argv = process.argv.slice(2);
  const value = (flag) => (argv.includes(flag) ? argv[argv.indexOf(flag) + 1] : undefined);
  const from = value("--from"), to = value("--to"), write = argv.includes("--write");
  const names = argv.filter((a, i) => !a.startsWith("--") && argv[i - 1] !== "--from" && argv[i - 1] !== "--to");
  if (!from || !to || names.length === 0) {
    console.error("usage: node scripts/lift-declarations.mjs --from <file> --to <file> <TypeName...> [--write]");
    process.exit(2);
  }
  if (!existsSync(from)) { console.error(`no such file: ${from}`); process.exit(1); }
  let result;
  try { result = plan(readFileSync(from, "utf8"), names); }
  catch (error) { console.error(String(error.message)); process.exit(1); }

  const movedLines = result.moved.split("\n").length;
  for (const block of result.blocks) console.log(`  ${block.name}  lines ${block.top + 1}-${block.end + 1}`);
  console.log(`\n${result.blocks.length} declaration(s), ${movedLines} lines, ${from} -> ${to}`);
  if (!write) {
    console.log("\nDry run. Pass --write to apply, then verify removed lines reappear unchanged.");
    return;
  }
  writeFileSync(from, result.remaining);
  const existing = existsSync(to) ? readFileSync(to, "utf8").replace(/\s*$/, "\n\n") : "import Foundation\n\n";
  writeFileSync(to, existing + result.moved + "\n");
  console.log("\nWritten. Now confirm it was a move, not an edit.");
}

if (import.meta.url === `file://${process.argv[1]}`) main();
