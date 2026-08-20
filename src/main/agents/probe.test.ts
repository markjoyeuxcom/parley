import { beforeEach, describe, expect, it, vi } from 'vitest'

/**
 * Checking whether a CLI is signed in must not cost anything.
 *
 * Codex's probe used to run a real turn — `codex exec 'Reply with exactly:
 * ready'` — on every launch. That is a paid turn against the user's
 * subscription spent to draw a status dot, and it answered the wrong question
 * exactly when it mattered: at the usage limit the turn fails, so the app said
 * "codex is installed but did not answer. Run `codex login` to sign in",
 * sending somebody to re-authenticate an account that was signed in and simply
 * out of credit for three days.
 */

const h = vi.hoisted(() => ({ capture: vi.fn(), findExecutable: vi.fn(() => '/usr/local/bin/codex') }))

vi.mock('@main/util/spawn', () => ({ capture: h.capture, runJsonl: vi.fn() }))
vi.mock('@main/util/environment', () => ({ findExecutable: h.findExecutable }))

const { CodexAdapter } = await import('./codex')
const { ClaudeAdapter } = await import('./claude')
const { AgyAdapter } = await import('./agy')

/** Every argv the probe ran, flattened for asking what it did. */
const argvs = (): string[][] => h.capture.mock.calls.map((call) => call[1] as string[])

function answering(status: string) {
  h.capture.mockImplementation((_bin: string, args: string[]) => {
    if (args[0] === '--version') {
      return Promise.resolve({ stdout: 'codex-cli 0.148.0', stderr: '', exitCode: 0, durationMs: 1, timedOut: false })
    }
    return Promise.resolve({ stdout: status, stderr: '', exitCode: 0, durationMs: 1, timedOut: false })
  })
}

beforeEach(() => {
  h.capture.mockReset()
  h.findExecutable.mockReturnValue('/usr/local/bin/codex')
})

describe('the codex health probe', () => {
  it('never runs a turn', async () => {
    answering('Logged in using ChatGPT')
    await new CodexAdapter().probe()

    // The property. `exec` is what bills; `login status` is free.
    for (const args of argvs()) {
      expect(args).not.toContain('exec')
    }
    expect(argvs().some((args) => args[0] === 'login' && args[1] === 'status')).toBe(true)
  })

  it('reads a signed-in answer', async () => {
    answering('Logged in using ChatGPT')
    const health = await new CodexAdapter().probe()

    expect(health.authenticated).toBe(true)
    expect(health.present).toBe(true)
    expect(health.version).toBe('codex-cli 0.148.0')
  })

  it('reads "Not logged in" as not signed in, and says something useful', async () => {
    // The substring trap: "Not logged in" contains "logged in".
    answering('Not logged in')
    const health = await new CodexAdapter().probe()

    expect(health.authenticated).toBe(false)
    expect(health.detail.toLowerCase()).toContain('not logged in')
  })

  it('does not report a spent quota as a login problem', async () => {
    // What the old probe did: the turn failed on the usage limit, so the dot
    // went red with advice to log in. `login status` cannot see the quota at
    // all, which is the point — being out of credit is not being signed out.
    answering('Logged in using ChatGPT')
    const health = await new CodexAdapter().probe()
    expect(health.authenticated).toBe(true)
    expect(health.detail).not.toMatch(/codex login/i)
  })
})

describe('the claude health probe', () => {
  const status = (json: string) => {
    h.capture.mockImplementation((_bin: string, args: string[]) =>
      Promise.resolve(
        args[0] === '--version'
          ? { stdout: '2.1.236 (Claude Code)', stderr: '', exitCode: 0, durationMs: 1, timedOut: false }
          : { stdout: json, stderr: '', exitCode: 0, durationMs: 1, timedOut: false },
      ),
    )
  }

  it('never runs a turn', async () => {
    status('{"loggedIn":true}')
    await new ClaudeAdapter().probe()
    // `-p` is what sends a prompt. Cheap on haiku is still billed.
    for (const args of argvs()) expect(args).not.toContain('-p')
    expect(argvs().some((a) => a[0] === 'auth' && a[1] === 'status')).toBe(true)
  })

  it('reads loggedIn from the JSON', async () => {
    status('{"loggedIn":true,"authMethod":"claude.ai"}')
    expect((await new ClaudeAdapter().probe()).authenticated).toBe(true)

    status('{"loggedIn":false}')
    expect((await new ClaudeAdapter().probe()).authenticated).toBe(false)
  })

  it('never repeats the account it found', async () => {
    // `auth status` answers with the email and organisation id. `detail` is
    // shown in the UI and carried in notices; who somebody is is not ours to
    // repeat, only whether they are signed in.
    status('{"loggedIn":false,"email":"someone@example.com","orgId":"24cf1642-6244"}')
    const health = await new ClaudeAdapter().probe()

    expect(health.detail).not.toContain('someone@example.com')
    expect(health.detail).not.toContain('24cf1642-6244')
    expect(health.detail).toMatch(/claude auth login/)
  })
})

describe('the agy health probe', () => {
  const listing = (stdout: string, exitCode = 0) => {
    h.capture.mockImplementation((_bin: string, args: string[]) =>
      Promise.resolve(
        args[0] === '--version'
          ? { stdout: 'Antigravity CLI 1.1.16', stderr: '', exitCode: 0, durationMs: 1, timedOut: false }
          : { stdout, stderr: '', exitCode, durationMs: 1, timedOut: false },
      ),
    )
  }

  it('lists models instead of running one', async () => {
    listing('gemini-3.7-flash-low\tGemini 3.7 Flash (Low)\n')
    const health = await new AgyAdapter().probe()

    expect(health.authenticated).toBe(true)
    expect(argvs().some((a) => a[0] === 'models')).toBe(true)
    // No prompt anywhere in what it ran.
    for (const args of argvs()) expect(args.join(' ')).not.toMatch(/Reply with exactly/)
  })

  it('is not signed in when nothing comes back', async () => {
    listing('', 1)
    const health = await new AgyAdapter().probe()
    expect(health.authenticated).toBe(false)
    expect(health.detail).toMatch(/sign in/i)
  })
})

