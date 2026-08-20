import { describe, expect, it } from 'vitest'
import { invokeCommand, type IpcContext } from './commands'

/**
 * The dispatch guard.
 *
 * `command` is an arbitrary string from the renderer, and both the schema and
 * handler lookups were bare property reads — so `constructor`, `toString` and
 * `__proto__` passed the existence checks and reached further in than any of
 * them should. Each happened to die later on `schema.safeParse is not a
 * function`, which the error envelope caught, so it was never exploitable. But
 * that guard was accidental: it held only while nothing on `Object.prototype`
 * was shaped like a Zod schema.
 */

// Unknown commands are refused before the context is touched.
const ctx = {} as IpcContext

describe('a command name cannot reach Object.prototype', () => {
  it('refuses inherited keys by name', async () => {
    for (const command of [
      'constructor',
      'toString',
      '__proto__',
      'hasOwnProperty',
      'valueOf',
      'isPrototypeOf',
      'propertyIsEnumerable',
    ]) {
      await expect(invokeCommand(ctx, { command, payload: {} })).rejects.toThrow(/unknown command/)
    }
  })

  it('still refuses an ordinary unknown command', async () => {
    await expect(invokeCommand(ctx, { command: 'pane.explode', payload: {} })).rejects.toThrow(
      /unknown command/,
    )
  })

  it('refuses a malformed request outright', async () => {
    await expect(invokeCommand(ctx, null)).rejects.toThrow(/malformed request/)
    await expect(invokeCommand(ctx, { payload: {} })).rejects.toThrow(/malformed request/)
  })
})
