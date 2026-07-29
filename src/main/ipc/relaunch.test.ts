import { describe, expect, it } from 'vitest'
import { relaunchIntoFreshBuild, type RelaunchApp } from './relaunch'

describe('relaunchIntoFreshBuild', () => {
  it('relaunches with one fresh-build flag before quitting, without exiting', () => {
    const calls: Array<{ operation: 'relaunch'; args: string[] } | { operation: 'quit' } | { operation: 'exit' }> = []
    const app: RelaunchApp = {
      relaunch: ({ args }) => calls.push({ operation: 'relaunch', args }),
      quit: () => calls.push({ operation: 'quit' }),
      exit: () => calls.push({ operation: 'exit' }),
    }

    relaunchIntoFreshBuild(app, [
      '/Applications/Parley.app/Contents/MacOS/Parley',
      '/Applications/Parley.app/Contents/Resources/app.asar',
      '--parley-fresh-build',
      '--inspect',
      '--parley-fresh-build',
    ])

    expect(calls).toEqual([
      {
        operation: 'relaunch',
        args: [
          '/Applications/Parley.app/Contents/Resources/app.asar',
          '--inspect',
          '--parley-fresh-build',
        ],
      },
      { operation: 'quit' },
    ])
  })
})
