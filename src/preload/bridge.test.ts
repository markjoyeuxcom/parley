import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { describe, expect, it } from 'vitest'

const preload = readFileSync(fileURLToPath(new URL('./index.ts', import.meta.url)), 'utf8')
const register = readFileSync(
  fileURLToPath(new URL('../main/ipc/register.ts', import.meta.url)),
  'utf8',
)

describe('the invoke envelope bridge', () => {
  it('unwraps main-process results in preload', () => {
    expect(preload).toMatch(/import \{ CH, unwrapInvokeResult,/)
    expect(preload).toMatch(/return unwrapInvokeResult\(result\)/)
    expect(preload).not.toMatch(/if \(!result\.ok\)/)
  })

  it('wraps command dispatch in register', () => {
    expect(register).toMatch(/import \{ CH, toInvokeResult,/)
    // The property, not the exact expression: dispatch happens inside
    // `toInvokeResult`, so a throw becomes an error envelope rather than a
    // rejected promise the preload would have to interpret. The handler grew a
    // senderFrame check between the two, which is why this no longer matches a
    // single line.
    expect(register).toMatch(/toInvokeResult\(/)
    expect(register).toMatch(/invokeCommand\(full, raw\)/)
    expect(register.indexOf('toInvokeResult(')).toBeLessThan(
      register.indexOf('invokeCommand(full, raw)'),
    )
    expect(register).not.toMatch(/err instanceof Error/)
  })
})
