import { strict as assert } from "node:assert";
import test from "node:test";
import { index, references, closure, group } from "./type-closure.mjs";
import { findDeclaration, plan } from "./lift-declarations.mjs";

const FILES = {
  "Vocabulary.swift": `import Foundation
public enum Colour: String, Codable { case red, blue }
public struct Label: Codable {
    public let colour: Colour
    public let text: String
}
`,
  "Engine.swift": `import Darwin
import Foundation
/// Doc comment that must travel with the declaration.
public struct Job: Codable {
    public let label: Label
    public let attempt: Int
}
public enum Trigger {
    case manual
    case scheduled(Colour)
}
`,
};
const fakeList = () => Object.keys(FILES);
const fakeRead = (path) => FILES[path.split("/").pop()];
const model = () => index("fake", fakeList, fakeRead);

test("closure follows stored properties, not every capitalised word", () => {
  const m = model();
  assert.deepEqual([...references("Job", m)].sort(), ["Label"]);
  assert.deepEqual([...closure("Job", m)].sort(), ["Colour", "Job", "Label"]);
});

test("closure follows enum associated values", () => {
  assert.deepEqual([...closure("Trigger", model())].sort(), ["Colour", "Trigger"]);
});

test("grouping reports which files need a platform import", () => {
  const m = model();
  const groups = group(closure("Job", m), m);
  const engine = groups.find((g) => g.file === "Engine.swift");
  const vocabulary = groups.find((g) => g.file === "Vocabulary.swift");
  assert.equal(engine.platform, true, "Engine.swift imports Darwin");
  assert.equal(vocabulary.platform, false, "Vocabulary.swift imports nothing platform-specific");
});

test("an unknown type is refused rather than reported as empty", () => {
  assert.throws(() => closure("Missing", model()), /no declaration found/);
});

test("lifting carries the doc comment and the whole body", () => {
  const { moved, remaining } = plan(FILES["Engine.swift"], ["Job"]);
  assert.match(moved, /Doc comment that must travel/);
  assert.match(moved, /public let attempt: Int/);
  assert.doesNotMatch(remaining, /public let attempt: Int/);
  assert.match(remaining, /public enum Trigger/, "unrelated declarations stay");
});

test("every moved line leaves the source exactly once", () => {
  const source = FILES["Engine.swift"];
  const { moved, remaining } = plan(source, ["Job"]);
  const count = (text, line) => text.split("\n").filter((l) => l === line).length;
  for (const line of moved.split("\n").filter((l) => l.trim())) {
    assert.equal(count(source, line) - count(remaining, line), 1, `line not moved exactly once: ${line}`);
  }
});

test("lifting refuses a name it cannot find completely", () => {
  assert.throws(() => plan(FILES["Engine.swift"], ["Nope"]), /could not find a complete declaration/);
  assert.equal(findDeclaration("public struct Open {".split("\n"), "Open"), null, "an unbalanced body is refused");
});
