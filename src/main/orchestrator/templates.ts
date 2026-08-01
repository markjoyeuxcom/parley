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

export const TEMPLATES: readonly ProjectTemplate[] = [WEB_APP, GO_SERVICE]

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
