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
    expect(register).toMatch(/toInvokeResult\(\(\) => invokeCommand\(full, raw\)\)/)
    expect(register).not.toMatch(/err instanceof Error/)
  })
})
