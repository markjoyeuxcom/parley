/**
 * Project templates.
 *
 * A template is a deterministic set of files plus the two commands that
 * prove them: install, then verify. It exists so a new project's harness is
 * GREEN BEFORE any feature milestone runs — the failure class where an agent
 * spends an hour on code that could never have been verified, because the
 * project could not run its own tests yet, is designed out rather than
 * remediated.
 *
 * Deliberately code, not user data: a template Parley writes into a fresh
 * directory is part of the app's behaviour and belongs under review with the
 * rest of it. `templates.test.ts` pins the load-bearing lines — the same
 * shape as ci.test.ts pinning the CI file.
 *
 * v1 ships exactly one lane, local web apps. A second template is a
 * deliberate act, not a config file someone drops in.
 */

export interface ProjectTemplate {
  id: string
  name: string
  description: string
  /** Argv, never a shell line — the spawn invariant reaches this far. */
  installCommand: string[]
  /** Must exit 0 before the workspace is recorded ready. */
  verifyCommand: string[]
  /** Repository-relative path → exact contents. */
  files: Record<string, string>
}

const GITIGNORE = `node_modules/
dist/
*.local
.DS_Store
`

const PACKAGE_JSON = `{
  "name": "PLACEHOLDER_NAME",
  "private": true,
  "type": "module",
  "scripts": {
    "dev": "vite",
    "build": "tsc --noEmit && vite build",
    "preview": "vite preview",
    "test": "vitest run",
    "typecheck": "tsc --noEmit",
    "verify": "npm run typecheck && npm test"
  },
  "devDependencies": {
    "typescript": "^5.7.0",
    "vite": "^6.0.0",
    "vitest": "^2.1.0"
  }
}
`

const TSCONFIG = `{
  "compilerOptions": {
    "target": "ES2022",
    "module": "ESNext",
    "moduleResolution": "bundler",
    "lib": ["ES2022", "DOM"],
    "strict": true,
    "noUncheckedIndexedAccess": true,
    "noEmit": true,
    "skipLibCheck": true,
    "types": ["vitest/globals"]
  },
  "include": ["src"]
}
`

const INDEX_HTML = `<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>PLACEHOLDER_NAME</title>
  </head>
  <body>
    <div id="app"></div>
    <script type="module" src="/src/main.ts"></script>
  </body>
</html>
`

const MAIN_TS = `import { greeting } from './greeting'

const app = document.querySelector<HTMLDivElement>('#app')
if (app) app.textContent = greeting('PLACEHOLDER_NAME')
`

const GREETING_TS = `/** The one function the starting test proves, so the harness is real. */
export function greeting(name: string): string {
  return \`\${name} is running.\`
}
`

const GREETING_TEST_TS = `import { describe, expect, it } from 'vitest'
import { greeting } from './greeting'

describe('greeting', () => {
  it('names the project', () => {
    expect(greeting('parley')).toBe('parley is running.')
  })
})
`

const README = `# PLACEHOLDER_NAME

Scaffolded by Parley.

    npm install
    npm run dev       # the app
    npm run verify    # typecheck + tests — what Parley runs to prove a milestone

The verification command is \`npm run verify\`. Keep it green: it is the
deterministic half of every milestone Parley executes here, and a milestone
whose tests cannot run cannot be reviewed honestly.
`

const WEB_APP: ProjectTemplate = {
  id: 'web-app',
  name: 'Local web app',
  description: 'TypeScript + Vite + Vitest, with a passing test so the harness is proven from the first commit.',
  // `npm install` rather than `npm ci`: there is no lockfile yet, and
  // manufacturing one would be a lie about what was resolved.
  installCommand: ['npm', 'install'],
  verifyCommand: ['npm', 'run', 'verify'],
  files: {
    'package.json': PACKAGE_JSON,
    'tsconfig.json': TSCONFIG,
    '.gitignore': GITIGNORE,
    'index.html': INDEX_HTML,
    'README.md': README,
    'src/main.ts': MAIN_TS,
    'src/greeting.ts': GREETING_TS,
    'src/greeting.test.ts': GREETING_TEST_TS,
  },
}

const GO_MOD = `module PLACEHOLDER_NAME

go 1.22
`

const GO_GITIGNORE = `PLACEHOLDER_NAME
*.test
*.out
.DS_Store
`

const GO_MAIN = `package main

import (
\t"fmt"
\t"os"
)

func main() {
\tname := "world"
\tif len(os.Args) > 1 {
\t\tname = os.Args[1]
\t}
\tfmt.Println(Greeting(name))
}
`

const GO_GREETING = `package main

// Greeting is the one piece of behaviour this scaffold ships, and its test
// asserts exactly what it does. A scaffold whose own test fails would hand
// milestone one a red suite and nothing to trust.
func Greeting(name string) string {
\treturn name + " is running."
}
`

const GO_GREETING_TEST = `package main

import "testing"

func TestGreeting(t *testing.T) {
\tif got := Greeting("parley"); got != "parley is running." {
\t\tt.Fatalf("Greeting(parley) = %q", got)
\t}
}
`

const GO_README = `# PLACEHOLDER_NAME

Scaffolded by Parley, and green before anything else ran.

The verification command is \`go test ./...\`. Keep it green: it is the
deterministic half of every milestone Parley executes here, and a milestone
whose tests cannot run cannot be reviewed honestly.

There is no dependency step to speak of — \`go mod tidy\` resolves what the
source actually imports, which for this scaffold is the standard library.
`

/**
 * The second lane, and the one that proves the first was not a special case.
 *
 * Go earns it by having no dependency-manager ceremony: both commands are a
 * single argv that exits 0, which is the whole contract. Python needs `uv` or
 * a venv, and a venv is two steps — which is why it is not here yet rather
 * than being faked with a shell line.
 */
const GO_SERVICE: ProjectTemplate = {
  id: 'go-service',
  name: 'Go program',
  description: 'A Go module with a passing test, so the harness is proven from the first commit.',
  // Resolves what the source imports. For this scaffold that is nothing, and
  // it stays a real step so a milestone that adds a dependency has one.
  installCommand: ['go', 'mod', 'tidy'],
  verifyCommand: ['go', 'test', './...'],
  files: {
    'go.mod': GO_MOD,
    '.gitignore': GO_GITIGNORE,
    'README.md': GO_README,
    'main.go': GO_MAIN,
    'greeting.go': GO_GREETING,
    'greeting_test.go': GO_GREETING_TEST,
  },
}

const PY_PROJECT = `[project]
name = "PLACEHOLDER_NAME"
version = "0.1.0"
description = "Scaffolded by Parley."
requires-python = ">=3.10"
dependencies = []

[dependency-groups]
dev = ["pytest>=8"]
`

const PY_GITIGNORE = `.venv/
__pycache__/
*.pyc
.pytest_cache/
.DS_Store
`

const PY_GREETING = `"""The one piece of behaviour this scaffold ships.

Its test asserts exactly what it does. A scaffold whose own test fails would
hand milestone one a red suite and nothing to trust.
"""


def greeting(name: str) -> str:
    return f"{name} is running."
`

const PY_GREETING_TEST = `from greeting import greeting


def test_greeting() -> None:
    assert greeting("parley") == "parley is running."
`

const PY_MAIN = `import sys

from greeting import greeting


def main() -> None:
    name = sys.argv[1] if len(sys.argv) > 1 else "world"
    print(greeting(name))


if __name__ == "__main__":
    main()
`

const PY_README = `# PLACEHOLDER_NAME

Scaffolded by Parley, and green before anything else ran.

The verification command is \`uv run pytest\`. Keep it green: it is the
deterministic half of every milestone Parley executes here, and a milestone
whose tests cannot run cannot be reviewed honestly.

Dependencies are managed by [uv](https://docs.astral.sh/uv/). \`uv sync\`
resolves them into \`.venv\`, and \`uv run\` uses that environment without
anyone having to remember to activate it.

There is deliberately no \`[build-system]\`: this is a project to work in, not
a package to publish, so uv installs its dependencies without trying to build
and install the project itself.
`

/**
 * The third lane, and the one that shows what the single-argv rule costs.
 *
 * Python's usual setup is two steps — create a virtual environment, then
 * install into it — and two steps cannot be one argv without a shell line,
 * which the spawn invariant forbids. uv collapses both: `uv sync` resolves and
 * installs, `uv run` executes inside the environment without anyone
 * remembering to activate it. The price is a tool that must be on the machine,
 * which is why the creator refuses by name rather than failing in the middle.
 */
const PYTHON_APP: ProjectTemplate = {
  id: 'python-app',
  name: 'Python project',
  description: 'A uv-managed Python project with a passing pytest, so the harness is proven from the first commit.',
  installCommand: ['uv', 'sync'],
  verifyCommand: ['uv', 'run', 'pytest'],
  files: {
    'pyproject.toml': PY_PROJECT,
    '.gitignore': PY_GITIGNORE,
    'README.md': PY_README,
    'main.py': PY_MAIN,
    'greeting.py': PY_GREETING,
    'test_greeting.py': PY_GREETING_TEST,
  },
}

const CARGO_TOML = `[package]
name = "PLACEHOLDER_NAME"
version = "0.1.0"
edition = "2021"

[dependencies]
`

const RUST_GITIGNORE = `target/
.DS_Store
`

const RUST_MAIN = `mod greeting;

use greeting::greeting;

fn main() {
    let name = std::env::args().nth(1).unwrap_or_else(|| "world".to_string());
    println!("{}", greeting(&name));
}
`

const RUST_GREETING = `//! The one piece of behaviour this scaffold ships.
//!
//! Its test asserts exactly what it does. A scaffold whose own test fails
//! would hand milestone one a red suite and nothing to trust.

pub fn greeting(name: &str) -> String {
    format!("{} is running.", name)
}

#[cfg(test)]
mod tests {
    use super::greeting;

    #[test]
    fn greets_by_name() {
        assert_eq!(greeting("parley"), "parley is running.");
    }
}
`

const RUST_README = `# PLACEHOLDER_NAME

Scaffolded by Parley, and green before anything else ran.

The verification command is \`cargo test\`. Keep it green: it is the
deterministic half of every milestone Parley executes here, and a milestone
whose tests cannot run cannot be reviewed honestly.

\`cargo fetch\` resolves what Cargo.toml declares, which for this scaffold is
nothing — it stays a real step so a milestone that adds a dependency has one.
`

/** Rust, and it fits the rule without any argument: two commands, two argv. */
const RUST_APP: ProjectTemplate = {
  id: 'rust-app',
  name: 'Rust program',
  description: 'A Cargo package with a passing test, so the harness is proven from the first commit.',
  installCommand: ['cargo', 'fetch'],
  verifyCommand: ['cargo', 'test'],
  files: {
    'Cargo.toml': CARGO_TOML,
    '.gitignore': RUST_GITIGNORE,
    'README.md': RUST_README,
    'src/main.rs': RUST_MAIN,
    'src/greeting.rs': RUST_GREETING,
  },
}

export const TEMPLATES: readonly ProjectTemplate[] = [WEB_APP, GO_SERVICE, PYTHON_APP, RUST_APP]

/**
 * Why this lane cannot be scaffolded on this machine, or null.
 *
 * Checked BEFORE a directory is created, because the alternative is a project
 * that exists, is committed, and then fails on its install step — leaving
 * someone to work out from a spawn error that the tool was never there. The
 * name of the missing tool is the whole answer, so the refusal says it.
 */
export function toolchainRefusal(
  template: ProjectTemplate,
  resolve: (name: string) => string | null,
): string | null {
  const tools = [template.installCommand[0], template.verifyCommand[0]]
  for (const tool of tools) {
    if (!tool || resolve(tool)) continue
    return `${template.name} needs \`${tool}\`, which is not on Parley's PATH. Install it and try again — nothing has been created.`
  }
  return null
}

export function templateById(id: string): ProjectTemplate | null {
  return TEMPLATES.find((template) => template.id === id) ?? null
}

/**
 * npm package names are narrow, and this one reaches package.json and the
 * page title. Anything outside the safe set is rewritten rather than
 * refused — the user named a project, not a package.
 */
export function packageNameFor(projectName: string): string {
  const slug = projectName
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9._-]+/g, '-')
    .replace(/^[-_.]+|[-_.]+$/g, '')
    .slice(0, 100)
  return slug || 'app'
}

/** The template's files with the project's own name substituted in. */
export function renderTemplate(
  template: ProjectTemplate,
  projectName: string,
): Record<string, string> {
  const name = packageNameFor(projectName)
  const rendered: Record<string, string> = {}
  for (const [path, contents] of Object.entries(template.files)) {
    rendered[path] = contents.replaceAll('PLACEHOLDER_NAME', name)
  }
  return rendered
}
