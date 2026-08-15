import { describe, expect, it } from 'vitest'
import { RESUME_PICKER_KINDS } from '@shared/domain'
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

  it('agy runs bare and never grows a resume flag', () => {
    // Agy has no session picker — it resumes by id (`--conversation <id>`),
    // which is a governed resume id by another name and has no business in a
    // pane. It is absent from RESUME_PICKER_KINDS so the menu item never
    // appears; this pins the other half, that a caller passing the flag
    // anyway cannot conjure an argument the CLI would misread.
    expect(commandFor('agy')).toEqual({ file: 'agy', args: [] })
    expect(commandFor('agy', true)).toEqual({ file: 'agy', args: [] })
  })

  it('every resumable kind actually accepts the resume it advertises', () => {
    // The guard against the two halves drifting: RESUME_PICKER_KINDS decides
    // whether the renderer offers "Resume a session…", and commandFor decides
    // what that does. A kind listed there whose command ignores `resume`
    // would render a menu item that silently opens a fresh session.
    for (const kind of RESUME_PICKER_KINDS) {
      expect(commandFor(kind, true).args).not.toEqual(commandFor(kind, false).args)
    }
  })

  it('a shell reads the login profile, and resume means nothing to it', () => {
    expect(commandFor('shell').args).toEqual(['-l'])
    expect(commandFor('shell', true).args).toEqual(['-l'])
  })
})
