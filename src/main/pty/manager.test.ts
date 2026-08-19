import { afterEach, describe, expect, it, vi } from 'vitest'
import { RESUME_PICKER_KINDS } from '@shared/domain'
import { PaneInputReadiness, PanePromptSubmitter, commandFor } from './manager'

afterEach(() => vi.useRealTimers())

describe('pane input readiness', () => {
  it('waits for startup output to settle before declaring the interactive prompt ready', () => {
    vi.useFakeTimers()
    const ready: string[] = []
    const gate = new PaneInputReadiness((paneId) => ready.push(paneId), 500)

    gate.observe('pane-1')
    vi.advanceTimersByTime(400)
    gate.observe('pane-1')
    vi.advanceTimersByTime(499)
    expect(ready).toEqual([])

    vi.advanceTimersByTime(1)
    expect(ready).toEqual(['pane-1'])

    gate.observe('pane-1')
    vi.advanceTimersByTime(500)
    expect(ready).toEqual(['pane-1'])
  })

  it('declares a silent pane ready at the ceiling, because some CLIs print nothing', () => {
    // The gate used to start counting at the FIRST BYTE of output, so a pane
    // that never printed anything never armed a timer and never became ready.
    // A queued work assignment then sat undelivered while the lane looked
    // perfectly healthy, until the pane exited hours later.
    vi.useFakeTimers()
    const ready: string[] = []
    const gate = new PaneInputReadiness((paneId) => ready.push(paneId), 500, 2_000)

    gate.arm('pane-1')
    // Not the quiet timeout: nothing has been observed, so the only clock
    // running is the ceiling.
    vi.advanceTimersByTime(1_999)
    expect(ready).toEqual([])
    vi.advanceTimersByTime(1)
    expect(ready).toEqual(['pane-1'])
  })

  it('keeps the armed ceiling when output does arrive', () => {
    // Arming must not restart or replace the ceiling — a noisy CLI that never
    // goes quiet still has to become ready on time.
    vi.useFakeTimers()
    const ready: string[] = []
    const gate = new PaneInputReadiness((paneId) => ready.push(paneId), 500, 2_000)

    gate.arm('pane-1')
    vi.advanceTimersByTime(1_000)
    for (let at = 0; at < 5; at += 1) {
      gate.observe('pane-1')
      vi.advanceTimersByTime(200)
    }
    expect(ready).toEqual(['pane-1'])
  })

  it('forgets a pane that exits before its prompt becomes ready', () => {
    vi.useFakeTimers()
    const ready: string[] = []
    const gate = new PaneInputReadiness((paneId) => ready.push(paneId), 500)

    gate.observe('pane-1')
    gate.forget('pane-1')
    vi.advanceTimersByTime(500)

    expect(ready).toEqual([])
  })

  it('declares readiness at a hard ceiling when startup control output never becomes quiet', () => {
    vi.useFakeTimers()
    const ready: string[] = []
    const gate = new PaneInputReadiness((paneId) => ready.push(paneId), 500, 2_000)

    gate.observe('pane-1')
    for (let elapsed = 400; elapsed < 2_000; elapsed += 400) {
      vi.advanceTimersByTime(400)
      gate.observe('pane-1')
    }
    expect(ready).toEqual([])

    vi.advanceTimersByTime(400)
    expect(ready).toEqual(['pane-1'])
  })
})

describe('interactive prompt submission', () => {
  it('lets a pasted prompt settle before sending Enter', () => {
    vi.useFakeTimers()
    const writes: string[] = []
    const submitter = new PanePromptSubmitter((_, data) => writes.push(data), 200)

    submitter.submit('pane-1', 'line one\nline two')
    expect(writes).toEqual(['line one line two'])

    vi.advanceTimersByTime(199)
    expect(writes).toHaveLength(1)
    vi.advanceTimersByTime(1)
    expect(writes).toEqual(['line one line two', '\r'])
  })

  it('does not press Enter after the pane has exited', () => {
    vi.useFakeTimers()
    const writes: string[] = []
    const submitter = new PanePromptSubmitter((_, data) => writes.push(data), 200)

    submitter.submit('pane-1', 'assignment')
    submitter.forget('pane-1')
    vi.advanceTimersByTime(200)

    expect(writes).toEqual(['assignment'])
  })
})

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
