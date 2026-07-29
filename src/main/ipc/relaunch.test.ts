import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { describe, expect, it } from 'vitest'
import {
  applyFreshBuildFlag,
  FRESH_BUILD_FLAG,
  relaunchIntoFreshBuild,
  type RelaunchApp,
} from './relaunch'

describe('applyFreshBuildFlag', () => {
  it('exposes the literal relaunch flag', () => {
    expect(FRESH_BUILD_FLAG).toBe('--parley-fresh-build')
  })

  it('deletes the inherited dev-server URL and reports a fresh-build relaunch', () => {
    const env: Record<string, string | undefined> = {
      ELECTRON_RENDERER_URL: 'http://localhost:5173',
    }

    expect(applyFreshBuildFlag(['/Applications/Parley', FRESH_BUILD_FLAG], env)).toBe(true)
    expect('ELECTRON_RENDERER_URL' in env).toBe(false)
  })

  it('leaves the dev-server URL in place for an ordinary launch', () => {
    const env: Record<string, string | undefined> = {
      ELECTRON_RENDERER_URL: 'http://localhost:5173',
    }

    expect(applyFreshBuildFlag(['/Applications/Parley'], env)).toBe(false)
    expect(env['ELECTRON_RENDERER_URL']).toBe('http://localhost:5173')
  })
})

describe('relaunchIntoFreshBuild', () => {
  it('round-trips one fresh-build flag before quitting, without exiting', () => {
    const calls: Array<{ operation: 'relaunch'; args: string[] } | { operation: 'quit' } | { operation: 'exit' }> = []
    const app: RelaunchApp = {
      relaunch: ({ args }) => calls.push({ operation: 'relaunch', args }),
      quit: () => calls.push({ operation: 'quit' }),
      exit: () => calls.push({ operation: 'exit' }),
    }

    relaunchIntoFreshBuild(app, [
      '/Applications/Parley.app/Contents/MacOS/Parley',
      '/Applications/Parley.app/Contents/Resources/app.asar',
      FRESH_BUILD_FLAG,
      '--inspect',
      FRESH_BUILD_FLAG,
    ])

    expect(calls).toEqual([
      {
        operation: 'relaunch',
        args: [
          '/Applications/Parley.app/Contents/Resources/app.asar',
          '--inspect',
          FRESH_BUILD_FLAG,
        ],
      },
      { operation: 'quit' },
    ])

    const relaunched = calls[0]
    expect(relaunched?.operation).toBe('relaunch')
    if (relaunched?.operation !== 'relaunch') throw new Error('expected relaunch')

    const env: Record<string, string | undefined> = {
      ELECTRON_RENDERER_URL: 'http://localhost:5173',
    }
    expect(applyFreshBuildFlag(['/Applications/Parley', ...relaunched.args], env)).toBe(true)
    expect('ELECTRON_RENDERER_URL' in env).toBe(false)
  })
})

describe('main entry', () => {
  it('applies the fresh-build flag before reading the renderer URL', () => {
    const index = readFileSync(fileURLToPath(new URL('../index.ts', import.meta.url)), 'utf8')
    const applyCall = 'applyFreshBuildFlag(process.argv, process.env)'
    const rendererUrlRead = "process.env['ELECTRON_RENDERER_URL']"

    expect(index).toContain(
      "import { applyFreshBuildFlag } from '@main/ipc/relaunch'",
    )
    expect(index.indexOf(applyCall)).toBeGreaterThan(-1)
    expect(index.indexOf(rendererUrlRead)).toBeGreaterThan(index.indexOf(applyCall))
  })
})
