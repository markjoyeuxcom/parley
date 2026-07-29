import { describe, expect, it } from 'vitest'
import { COMMANDS, toInvokeResult, unwrapInvokeResult } from './ipc'

describe('finding ledger IPC schemas', () => {
  it('requires a session when listing entries', () => {
    expect(COMMANDS['ledger.list'].safeParse({ sessionId: 'session-1' }).success).toBe(true)
    expect(COMMANDS['ledger.list'].safeParse({}).success).toBe(false)
  })

  it('requires an explained terminal disposition', () => {
    const request = {
      sessionId: 'session-1',
      findingId: 'finding-1',
      occurrenceId: 'occurrence-1',
      state: 'resolved',
      note: 'The regression test now covers the failing path.',
    }

    expect(COMMANDS['ledger.dispose'].safeParse(request).success).toBe(true)
    expect(COMMANDS['ledger.dispose'].safeParse({ ...request, occurrenceId: null }).success).toBe(true)
    expect(COMMANDS['ledger.dispose'].safeParse({ ...request, note: '' }).success).toBe(false)
    expect(COMMANDS['ledger.dispose'].safeParse({ ...request, note: '   ' }).success).toBe(false)
    expect(COMMANDS['ledger.dispose'].safeParse({ ...request, state: 'open' }).success).toBe(false)
  })
})

describe('invoke result envelope', () => {
  it('wraps and unwraps a successful invocation', async () => {
    const result = await toInvokeResult(async () => 'value')

    expect(result).toEqual({ ok: true, value: 'value' })
    expect(unwrapInvokeResult(result)).toBe('value')
  })

  it('preserves an Error message across the invoke boundary', async () => {
    const result = await toInvokeResult(() => {
      throw new Error('main refused the command')
    })

    expect(result).toEqual({ ok: false, error: 'main refused the command' })
    expect(() => unwrapInvokeResult(result)).toThrow('main refused the command')
  })

  it('stringifies a non-Error rejection', async () => {
    const result = await toInvokeResult(() => Promise.reject('plain failure'))

    expect(result).toEqual({ ok: false, error: 'plain failure' })
  })
})
