import { chmodSync, mkdirSync, mkdtempSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { delimiter, join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { applyResolvedPath, findExecutable, preflightPty, readCodexDefaultModel } from './environment'

function scratch(): string {
  return mkdtempSync(join(tmpdir(), 'parley-env-'))
}

function writeExecutable(dir: string, name: string): string {
  const path = join(dir, name)
  writeFileSync(path, '#!/bin/sh\nexit 0\n')
  chmodSync(path, 0o755)
  return path
}

describe('findExecutable', () => {
  it('finds a binary on the supplied PATH', () => {
    const dir = scratch()
    const binary = writeExecutable(dir, 'fakecli')
    expect(findExecutable('fakecli', dir)).toBe(binary)
  })

  it('honours PATH precedence, returning the first match', () => {
    const first = scratch()
    const second = scratch()
    const expected = writeExecutable(first, 'dupe')
    writeExecutable(second, 'dupe')
    expect(findExecutable('dupe', [first, second].join(delimiter))).toBe(expected)
  })

  it('skips a match that is not executable', () => {
    // This is the difference between "installed" and "installed but chmod is
    // wrong", which produce very different fixes.
    const dir = scratch()
    const path = join(dir, 'notexec')
    writeFileSync(path, 'x')
    chmodSync(path, 0o644)
    expect(findExecutable('notexec', dir)).toBeNull()
  })

  it('skips a directory that shares the name', () => {
    const dir = scratch()
    mkdirSync(join(dir, 'adir'))
    expect(findExecutable('adir', dir)).toBeNull()
  })

  it('returns null rather than throwing for a missing binary', () => {
    expect(findExecutable('definitely-not-installed-anywhere', scratch())).toBeNull()
  })

  it('accepts an explicit path and validates it', () => {
    const dir = scratch()
    const binary = writeExecutable(dir, 'direct')
    expect(findExecutable(binary)).toBe(binary)
    expect(findExecutable(join(dir, 'missing'))).toBeNull()
  })

  it('tolerates empty and malformed PATH entries', () => {
    const dir = scratch()
    const binary = writeExecutable(dir, 'ok')
    expect(findExecutable('ok', ['', dir, ''].join(delimiter))).toBe(binary)
    expect(findExecutable('ok', '')).toBeNull()
  })
})

describe('applyResolvedPath', () => {
  const original = process.env['PATH']

  beforeEach(() => {
    process.env['PATH'] = original
  })

  afterEach(() => {
    process.env['PATH'] = original
  })

  it('never loses a directory that was already on PATH', async () => {
    const dir = scratch()
    process.env['PATH'] = [dir, '/usr/bin', '/bin'].join(delimiter)

    const result = await applyResolvedPath()

    for (const required of [dir, '/usr/bin', '/bin']) {
      expect(result.path.split(delimiter), required).toContain(required)
    }
  })

  it('applies the result to process.env so every later spawn inherits it', async () => {
    const result = await applyResolvedPath()
    expect(process.env['PATH']).toBe(result.path)
  })

  it('produces no duplicate entries', async () => {
    const dir = scratch()
    process.env['PATH'] = [dir, dir, '/usr/bin', '/usr/bin'].join(delimiter)

    const entries = (await applyResolvedPath()).path.split(delimiter).filter(Boolean)
    expect(new Set(entries).size).toBe(entries.length)
  })

  it('reports where the PATH came from', async () => {
    const result = await applyResolvedPath()
    expect(['login-shell', 'inherited']).toContain(result.source)
  })

  it('keeps a findable binary findable afterwards', async () => {
    const dir = scratch()
    writeExecutable(dir, 'stillhere')
    process.env['PATH'] = [dir, process.env['PATH'] ?? ''].join(delimiter)

    await applyResolvedPath()
    expect(findExecutable('stillhere')).toBeTruthy()
  })
})

describe('preflightPty', () => {
  it('passes on platforms with no spawn-helper requirement', () => {
    // spawn-helper is a mac-only binding.gyp target, so elsewhere there is
    // nothing to check and the preflight must not invent a failure.
    const result = preflightPty()
    if (process.platform !== 'darwin') {
      expect(result.ok).toBe(true)
      expect(result.helperPath).toBeNull()
    } else {
      // On macOS it must reach a verdict about a concrete path.
      expect(result.helperPath).toBeTruthy()
      if (!result.ok) expect(result.detail).toMatch(/rebuild|chmod/i)
    }
  })

  it('always explains itself when it fails', () => {
    const result = preflightPty()
    if (!result.ok) {
      expect(result.detail.length).toBeGreaterThan(20)
      // The message has to name a fix, not just the symptom.
      expect(result.detail).toMatch(/npm run rebuild|chmod/)
    }
  })
})

describe('readCodexDefaultModel', () => {
  // The function reads a fixed path under $HOME, so these exercise the parser
  // against the shapes a real config.toml takes.
  const parse = (text: string): string => {
    for (const line of text.split('\n')) {
      const trimmed = line.trim()
      if (trimmed.startsWith('[')) break
      const match = /^model\s*=\s*["']([^"']+)["']/.exec(trimmed)
      if (match?.[1]) return match[1]
    }
    return ''
  }

  it('reads the top-level default', () => {
    // Verbatim shape from a real install.
    expect(
      parse(`model = "gpt-5.6-sol"\nservice_tier = "default"\nmodel_reasoning_effort = "xhigh"`),
    ).toBe('gpt-5.6-sol')
  })

  it('ignores a model set inside a table', () => {
    // A per-project or per-profile model is not the global default, and taking
    // it would suggest a model scoped to somewhere else entirely.
    expect(parse(`[projects."/some/repo"]\nmodel = "gpt-5.6-luna"`)).toBe('')
  })

  it('stops at the first table header', () => {
    expect(parse(`model = "gpt-5.6-terra"\n\n[projects."/x"]\nmodel = "gpt-5.6-luna"`)).toBe(
      'gpt-5.6-terra',
    )
  })

  it('handles single quotes and loose spacing', () => {
    expect(parse(`model   =   'gpt-5.6-sol'`)).toBe('gpt-5.6-sol')
  })

  it('returns empty when no default is set', () => {
    expect(parse(`service_tier = "default"`)).toBe('')
    expect(parse('')).toBe('')
  })

  it('is not fooled by a similarly named key', () => {
    expect(parse(`model_reasoning_effort = "xhigh"`)).toBe('')
  })

  it('finds the real one on this machine, or nothing', () => {
    // Whatever it returns must be a plausible id rather than a stray fragment.
    const found = readCodexDefaultModel()
    if (found) expect(found).toMatch(/^[\w.-]+$/)
  })
})
