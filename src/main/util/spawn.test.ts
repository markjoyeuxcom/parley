import { tmpdir } from 'node:os'
import { describe, expect, it } from 'vitest'
import { capture, isShellFree, runJsonl, splitCommand } from './spawn'

/**
 * These two functions are the boundary between agent-authored text and a
 * process. Everything they let through is spawned as bare argv with no shell, so
 * their job is to be conservative rather than clever.
 */

describe('splitCommand', () => {
  it('splits a plain command', () => {
    expect(splitCommand('npm test')).toEqual(['npm', 'test'])
    expect(splitCommand('cargo build --release')).toEqual(['cargo', 'build', '--release'])
  })

  it('keeps quoted arguments together', () => {
    expect(splitCommand('npm test -- --grep "two words"')).toEqual([
      'npm',
      'test',
      '--',
      '--grep',
      'two words',
    ])
    expect(splitCommand("pytest -k 'test one'")).toEqual(['pytest', '-k', 'test one'])
  })

  it('collapses runs of whitespace', () => {
    expect(splitCommand('  npm    run   build  ')).toEqual(['npm', 'run', 'build'])
  })

  it('preserves a deliberately empty quoted argument', () => {
    expect(splitCommand('cmd ""')).toEqual(['cmd', ''])
  })

  it('rejects unbalanced quotes rather than guessing', () => {
    expect(splitCommand('npm test "unclosed')).toBeNull()
  })

  it('returns null for nothing usable', () => {
    expect(splitCommand('')).toBeNull()
    expect(splitCommand('    ')).toBeNull()
  })
})

describe('isShellFree', () => {
  it('accepts ordinary commands', () => {
    expect(isShellFree('npm test')).toBe(true)
    expect(isShellFree('go test ./...')).toBe(true)
    expect(isShellFree('pytest -k test_one')).toBe(true)
  })

  it('rejects every shell construct that could change what runs', () => {
    for (const line of [
      'npm test | tee out.log',
      'npm test && rm -rf /',
      'npm test; echo done',
      'npm test > out.txt',
      'echo $HOME',
      'echo `whoami`',
      'rm -rf $(pwd)',
      'ls *.ts',
      'cat ~/.ssh/id_rsa',
      'npm test\nrm -rf .',
      'sh -c {echo}',
    ]) {
      expect(isShellFree(line), line).toBe(false)
    }
  })
})

describe('capture reports how a process ended', () => {
  // A command that segfaults and a command whose tests failed both arrive as a
  // non-zero result. Conflating them tells a reviewer "the tests failed" when
  // the truth is "nothing ran", and sends an executor to fix the wrong thing.
  const node = process.execPath

  it('reports a clean exit with no signal', async () => {
    const result = await capture(node, ['-e', 'process.exit(0)'], tmpdir())
    expect(result.exitCode).toBe(0)
    expect(result.signal).toBeNull()
  })

  it('reports a non-zero exit with no signal — a failure, not a crash', async () => {
    const result = await capture(node, ['-e', 'process.exit(3)'], tmpdir())
    expect(result.exitCode).toBe(3)
    expect(result.signal).toBeNull()
  })

  it('names the signal when the process is killed', async () => {
    const result = await capture(
      node,
      ['-e', 'process.kill(process.pid, "SIGSEGV")'],
      tmpdir(),
    )
    expect(result.signal).toBe('SIGSEGV')
    // The distinguishing fact is the signal. The exit code alone cannot tell
    // this apart from an ordinary failure.
    expect(result.exitCode).toBe(-1)
  })

  it('names the signal when a timeout kills the process', async () => {
    const result = await capture(node, ['-e', 'setTimeout(() => {}, 60000)'], tmpdir(), 300)
    expect(result.timedOut).toBe(true)
    expect(result.signal).toBe('SIGTERM')
  })

  it('still captures output from a process that later dies', async () => {
    const result = await capture(
      node,
      [
        '-e',
        // Killed from the write callback, not the next line. console.log to a pipe
        // is asynchronous and SIGABRT is not, so signalling immediately raced the
        // flush: this passed on one machine and failed on another. The behaviour
        // under test is that output already written survives the death, which needs
        // the write to have actually happened.
        'process.stdout.write("ran some tests\\n", () => process.kill(process.pid, "SIGABRT"))',
      ],
      tmpdir(),
    )
    expect(result.stdout).toContain('ran some tests')
    expect(result.signal).toBe('SIGABRT')
  })
})

describe('runJsonl termination causes', () => {
  const node = process.execPath
  const sleepForever = ['-e', 'setTimeout(() => {}, 60000)']

  // "The run was cancelled" and "the run hit its deadline" demand opposite
  // responses; both arrive as a termination, so the flag is the only witness.
  it('marks a deadline kill as timed out', async () => {
    const result = await runJsonl({
      command: node,
      args: sleepForever,
      cwd: tmpdir(),
      timeoutMs: 150,
      onEvent: () => {},
    })
    expect(result.terminated).toBe(true)
    expect(result.timedOut).toBe(true)
  })

  it('marks an abort as cancelled, never timed out', async () => {
    const controller = new AbortController()
    setTimeout(() => controller.abort(), 100)
    const result = await runJsonl({
      command: node,
      args: sleepForever,
      cwd: tmpdir(),
      timeoutMs: 60_000,
      signal: controller.signal,
      onEvent: () => {},
    })
    expect(result.terminated).toBe(true)
    expect(result.timedOut).toBe(false)
  })
})

describe('runJsonl stdin delivery', () => {
  const node = process.execPath

  it('witnesses a prompt flushed through stdin', async () => {
    const events: Record<string, unknown>[] = []
    const result = await runJsonl({
      command: node,
      args: [
        '-e',
        'let body=""; process.stdin.setEncoding("utf8"); process.stdin.on("data", c => body += c); process.stdin.on("end", () => console.log(JSON.stringify({body})))',
      ],
      cwd: tmpdir(),
      stdin: 'prompt only on stdin',
      onEvent: (event) => events.push(event),
    })
    expect(result.exitCode).toBe(0)
    expect(result.stdinDelivered).toBe(true)
    expect(events).toEqual([{ body: 'prompt only on stdin' }])
  })

  it('does not claim delivery when the process could not be spawned', async () => {
    const result = await runJsonl({
      command: '/definitely-not-a-real-parley-command',
      args: [],
      cwd: tmpdir(),
      stdin: 'undelivered prompt',
      onEvent: () => {},
    })
    expect(result.exitCode).toBe(-1)
    expect(result.stdinDelivered).toBe(false)
  })

  it('does not claim a large prompt was delivered when the child exits without draining it', async () => {
    const result = await runJsonl({
      command: node,
      args: ['-e', 'process.stdin.destroy(); process.exit(2)'],
      cwd: tmpdir(),
      stdin: 'x'.repeat(1024 * 1024),
      onEvent: () => {},
    })
    expect(result.exitCode).toBe(2)
    expect(result.stdinDelivered).toBe(false)
  })
})
