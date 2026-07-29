import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { describe, expect, it } from 'vitest'

const ci = readFileSync(fileURLToPath(new URL('../../.gitlab-ci.yml', import.meta.url)), 'utf8')

function topLevelBlock(key: string): string {
  const lines = ci.split('\n')
  const start = lines.findIndex((line) => line === `${key}:`)
  if (start === -1) return ''

  const end = lines.findIndex(
    (line, index) => index > start && /^[^\s#][^:]*:\s*(?:.*)?$/.test(line),
  )
  return lines.slice(start, end === -1 ? undefined : end).join('\n')
}

describe('GitLab CI', () => {
  it('runs the blocking verify job in the test stage', () => {
    const stages = topLevelBlock('stages')
    const verify = topLevelBlock('verify')

    expect(stages).toMatch(/^- test$/m)
    expect(verify).toMatch(/^verify:$/m)
    expect(verify).toMatch(/^\s+stage: test$/m)
    expect(verify).toMatch(/^\s+image: node:/m)
    expect(verify).toMatch(/^\s+- npm ci --ignore-scripts$/m)
    expect(verify).toMatch(/^\s+- npm run verify$/m)
    expect(verify).toMatch(/^\s+allow_failure: false$/m)
    expect(verify).not.toMatch(/^\s+allow_failure: true$/m)
  })
})
