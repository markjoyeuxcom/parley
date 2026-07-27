import { describe, expect, it } from 'vitest'
import { COMMANDS } from './ipc'

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
