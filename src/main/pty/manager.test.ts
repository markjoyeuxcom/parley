import { describe, expect, it } from 'vitest'
import { commandFor } from './manager'

describe('pane command construction', () => {
  it('runs the CLIs bare, interactively — their own TUIs, their own permissions', () => {
    expect(commandFor('claude')).toEqual({ file: 'claude', args: [] })
    expect(commandFor('codex')).toEqual({ file: 'codex', args: [] })
  })

  it('resume opens each CLI’s own session picker, never a governed resume id', () => {
    expect(commandFor('claude', true).args).toEqual(['--resume'])
    expect(commandFor('codex', true).args).toEqual(['resume'])
  })

  it('a shell reads the login profile, and resume means nothing to it', () => {
    expect(commandFor('shell').args).toEqual(['-l'])
    expect(commandFor('shell', true).args).toEqual(['-l'])
  })
})
