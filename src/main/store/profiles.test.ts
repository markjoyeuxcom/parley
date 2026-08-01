import { describe, expect, it } from 'vitest'
import { openDatabase } from './db'
import { Repo } from './repo'

/**
 * Named seat configurations.
 *
 * Small on purpose — a profile is four fields and a name, never credentials.
 * The properties worth pinning are the ones a person would trip over: two
 * spellings of one name being one identity, and deletion not reaching what
 * the name was already stamped on.
 */

describe('agent profiles', () => {
  it('creates, lists by name, and forgets', () => {
    const repo = new Repo(openDatabase(':memory:'))
    repo.createAgentProfile({ name: 'Zed architect', vendor: 'claude', model: 'opus', effort: 'max', persona: 'terse' })
    const fast = repo.createAgentProfile({ name: 'Fast reviewer', vendor: 'codex', model: '', effort: 'low', persona: '' })

    expect(repo.listAgentProfiles().map((p) => p.name)).toEqual(['Fast reviewer', 'Zed architect'])

    repo.forgetAgentProfile(fast.id)
    expect(repo.listAgentProfiles().map((p) => p.name)).toEqual(['Zed architect'])
  })

  it('treats two casings of one name as one identity', () => {
    // "fast reviewer" and "Fast Reviewer" would be a single agent to any
    // person reading a journal, so they are a single name here too.
    const repo = new Repo(openDatabase(':memory:'))
    repo.createAgentProfile({ name: 'Fast reviewer', vendor: 'codex', model: '', effort: 'low', persona: '' })
    expect(() =>
      repo.createAgentProfile({ name: 'FAST REVIEWER', vendor: 'claude', model: '', effort: 'high', persona: '' }),
    ).toThrow()
  })

  it('refuses a blank name rather than storing an unnameable identity', () => {
    const repo = new Repo(openDatabase(':memory:'))
    expect(() =>
      repo.createAgentProfile({ name: '   ', vendor: 'claude', model: '', effort: 'high', persona: '' }),
    ).toThrow(/name/)
  })
})
