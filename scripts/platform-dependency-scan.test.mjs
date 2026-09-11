import { strict as assert } from "node:assert";
import test from "node:test";
import { scanSource, scanDirectory, compare, BASELINE } from "./platform-dependency-scan.mjs";

test("scanSource finds only real top-level platform imports", () => {
  assert.deepEqual(scanSource("import Foundation\nimport Darwin\n"), ["Darwin"]);
  assert.deepEqual(scanSource("import Foundation\n"), []);
  // A mention inside a comment or string is not an import.
  assert.deepEqual(scanSource("// import Darwin\nlet s = \"import Darwin\"\n"), []);
  // Conditional imports still count: the file needs the platform.
  assert.deepEqual(scanSource("import CryptoKit\nimport Security\n").sort(), ["CryptoKit", "Security"]);
});

test("the live baseline matches the repository", () => {
  const found = scanDirectory("native/Sources/ParleyCore");
  assert.deepEqual(compare(found), [], "ParleyCore's platform surface drifted from the recorded baseline");
});

test("a new file taking a platform import fails the guard", () => {
  const found = { ...scanDirectory("native/Sources/ParleyCore"), "BrandNew.swift": ["Darwin"] };
  const problems = compare(found);
  assert.equal(problems.length, 1);
  assert.match(problems[0], /BrandNew\.swift gained a platform import/);
});

test("a listed file taking an additional framework fails the guard", () => {
  const found = scanDirectory("native/Sources/ParleyCore");
  const file = Object.keys(BASELINE)[0];
  const problems = compare({ ...found, [file]: [...found[file], "AppKit"].sort() });
  assert.equal(problems.length, 1);
  assert.match(problems[0], /the baseline records/);
});

test("the guard is a ratchet: a file that stops needing a platform import must be removed", () => {
  const found = scanDirectory("native/Sources/ParleyCore");
  const file = Object.keys(BASELINE)[0];
  const reduced = { ...found };
  delete reduced[file];
  const problems = compare(reduced);
  assert.equal(problems.length, 1);
  assert.match(problems[0], /no longer carries a platform import/);
});
