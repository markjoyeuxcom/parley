import { describe, expect, it } from 'vitest'
import { isShellFree } from '@shared/command'
import { packageNameFor, renderTemplate, TEMPLATES, templateById } from './templates'

/**
 * A template is code Parley writes into a stranger's empty folder, so the
 * load-bearing lines are pinned here the way ci.test.ts pins the CI file:
 * if someone changes what a new project promises, this file has to say so.
 */

describe('the shipped templates', () => {
  it('ships the lanes it means to, and no others', () => {
    // Each template is a deliberate act, not a drive-by addition — a lane that
    // cannot be verified from its first commit is worse than no lane.
    expect(TEMPLATES.map((template) => template.id)).toEqual(['web-app', 'go-service'])
    expect(templateById('web-app')?.name).toBe('Local web app')
    expect(templateById('go-service')?.name).toBe('Go program')
    expect(templateById('nope')).toBeNull()
  })

  it('gives every lane an install and a verify that are single argv', () => {
    // The real constraint on a new language, and the reason Python is not here
    // yet: a venv is two steps, and faking it with a shell line would break the
    // spawn invariant this whole harness rests on.
    for (const template of TEMPLATES) {
      expect(template.installCommand.length).toBeGreaterThan(0)
      expect(template.verifyCommand.length).toBeGreaterThan(0)
    }
  })

  it('ships a Go lane whose own test asserts its own function', () => {
    const template = templateById('go-service')
    expect(template?.verifyCommand).toEqual(['go', 'test', './...'])
    expect(template?.files['greeting.go']).toContain('return name + " is running."')
    expect(template?.files['greeting_test.go']).toContain('"parley is running."')
    // The module line carries the project name, like package.json does.
    expect(template?.files['go.mod']).toContain('module PLACEHOLDER_NAME')
  })

  it('runs its commands as argv, never as a shell line', () => {
    for (const template of TEMPLATES) {
      expect(Array.isArray(template.installCommand)).toBe(true)
      expect(Array.isArray(template.verifyCommand)).toBe(true)
      for (const word of [...template.installCommand, ...template.verifyCommand]) {
        expect(isShellFree(word)).toBe(true)
      }
    }
  })

  it('promises a verify script that is what Parley will actually run', () => {
    const template = templateById('web-app')
    if (!template) throw new Error('expected the web-app template')
    // The contract in three places has to agree: the verify command, the
    // script it invokes, and what that script does.
    expect(template.verifyCommand).toEqual(['npm', 'run', 'verify'])
    const pkg = JSON.parse(template.files['package.json'] ?? '{}') as {
      scripts?: Record<string, string>
    }
    expect(pkg.scripts?.['verify']).toBe('npm run typecheck && npm test')
    expect(pkg.scripts?.['typecheck']).toBe('tsc --noEmit')
    expect(pkg.scripts?.['test']).toBe('vitest run')
  })

  it('ships a test that already passes, so the harness is proven not hoped', () => {
    const template = templateById('web-app')
    const test = template?.files['src/greeting.test.ts'] ?? ''
    const source = template?.files['src/greeting.ts'] ?? ''
    // The starting test asserts the starting function's actual behaviour —
    // a scaffold whose own test fails would hand milestone 1 a red suite.
    expect(test).toContain("expect(greeting('parley')).toBe('parley is running.')")
    expect(source).toContain('return `${name} is running.`')
  })

  it('ignores node_modules, so the first commit is the project and not its deps', () => {
    expect(templateById('web-app')?.files['.gitignore']).toContain('node_modules/')
  })

  it('substitutes the project name everywhere, leaving no placeholder behind', () => {
    const template = templateById('web-app')
    if (!template) throw new Error('expected the web-app template')
    const rendered = renderTemplate(template, 'My Great App')
    for (const [path, contents] of Object.entries(rendered)) {
      expect(contents, `${path} still holds a placeholder`).not.toContain('PLACEHOLDER_NAME')
    }
    expect(JSON.parse(rendered['package.json'] ?? '{}').name).toBe('my-great-app')
    expect(rendered['index.html']).toContain('<title>my-great-app</title>')
  })

  it('rewrites a project name into a legal package name rather than refusing one', () => {
    // The user named a project, not an npm package.
    expect(packageNameFor('My Great App')).toBe('my-great-app')
    expect(packageNameFor('  Spaces  ')).toBe('spaces')
    expect(packageNameFor('Ünïcødé ✨ thing')).toBe('n-c-d-thing')
    expect(packageNameFor('---')).toBe('app')
    expect(packageNameFor('')).toBe('app')
    expect(packageNameFor('x'.repeat(300)).length).toBeLessThanOrEqual(100)
  })
})
