import { describe, expect, it } from 'vitest'
import { describeCommand, truncateCommand, unwrapShell } from './activity'

describe('unwrapShell', () => {
  it('strips the wrapper codex puts on nearly every command', () => {
    // Verbatim from a real run. The wrapper is identical on every line and
    // pushes the actual command past the visible width.
    expect(unwrapShell(`/bin/zsh -lc "pwd && rg --files -g 'AGENTS.md'"`)).toBe(
      `pwd && rg --files -g 'AGENTS.md'`,
    )
  })

  it('handles the common shells and flag spellings', () => {
    expect(unwrapShell('/bin/bash -lc "make test"')).toBe('make test')
    expect(unwrapShell('sh -c "go build ./..."')).toBe('go build ./...')
    expect(unwrapShell('zsh -ic "npm run dev"')).toBe('npm run dev')
    expect(unwrapShell(`/usr/bin/fish -c 'ls -la'`)).toBe('ls -la')
  })

  it('leaves a plain command untouched', () => {
    expect(unwrapShell('go test ./internal/forge/...')).toBe('go test ./internal/forge/...')
    expect(unwrapShell('npm test')).toBe('npm test')
  })

  it('does not mistake a program whose name merely contains a shell name', () => {
    expect(unwrapShell('shellcheck -x script.sh')).toBe('shellcheck -x script.sh')
    expect(unwrapShell('/usr/local/bin/bashate file')).toBe('/usr/local/bin/bashate file')
  })

  it('collapses newlines so one command stays one feed line', () => {
    expect(unwrapShell('/bin/zsh -lc "go build\n  ./..."')).toBe('go build ./...')
  })

  it('keeps the original when unwrapping would leave nothing', () => {
    expect(unwrapShell('/bin/zsh -lc ""')).toBe('/bin/zsh -lc ""')
  })
})

describe('truncateCommand', () => {
  it('leaves short commands alone', () => {
    expect(truncateCommand('npm test', 40)).toBe('npm test')
  })

  it('cuts on a word boundary rather than mid-token', () => {
    // The observed symptom was a feed line ending "rg --files | so", which reads
    // as though the command itself were malformed. The property that matters:
    // what survives is a whole-word prefix of the original.
    const source = 'alpha beta gamma delta epsilon zeta'
    const out = truncateCommand(source, 22)

    expect(out.endsWith('…')).toBe(true)
    const body = out.slice(0, -1)
    expect(source.startsWith(body)).toBe(true)
    // The character following the cut in the original is a space, so no token
    // was split.
    expect(source[body.length]).toBe(' ')
  })

  it('falls back to a hard cut when there is no usable boundary', () => {
    const out = truncateCommand('a'.repeat(50), 20)
    expect(out).toHaveLength(21)
    expect(out.endsWith('…')).toBe(true)
  })
})

describe('describeCommand', () => {
  it('unwraps and truncates together', () => {
    const raw = `/bin/zsh -lc "${'find . -name file '.repeat(20)}"`
    const out = describeCommand(raw)
    expect(out.startsWith('/bin/zsh')).toBe(false)
    expect(out.startsWith('find .')).toBe(true)
    expect(out.length).toBeLessThanOrEqual(161)
  })
})
