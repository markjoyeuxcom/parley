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

  it('edits every field in place, keeping the id and the creation time', () => {
    // Editing must not be delete-and-recreate: the id is what a roster row is
    // keyed by, and createdAt is the only ordering fact a profile carries.
    const repo = new Repo(openDatabase(':memory:'))
    const made = repo.createAgentProfile({
      name: 'Fast reviewer',
      vendor: 'codex',
      model: '',
      effort: 'low',
      persona: '',
    })

    const edited = repo.updateAgentProfile(made.id, {
      name: 'Careful reviewer',
      vendor: 'claude',
      model: 'opus',
      effort: 'max',
      persona: 'terse',
    })

    expect(edited).toEqual({
      id: made.id,
      name: 'Careful reviewer',
      vendor: 'claude',
      model: 'opus',
      effort: 'max',
      persona: 'terse',
      createdAt: made.createdAt,
    })
    expect(repo.listAgentProfiles()).toEqual([edited])
  })

  it('lets a profile keep its own name through an edit', () => {
    // The unique index is NOCASE, so an edit that leaves the name alone must
    // not collide with the row being edited. Renaming to your own name in a
    // different casing is the same fix.
    const repo = new Repo(openDatabase(':memory:'))
    const made = repo.createAgentProfile({
      name: 'Fast reviewer',
      vendor: 'codex',
      model: '',
      effort: 'low',
      persona: '',
    })

    expect(() =>
      repo.updateAgentProfile(made.id, {
        name: 'FAST REVIEWER',
        vendor: 'codex',
        model: 'gpt-5.6-sol',
        effort: 'low',
        persona: '',
      }),
    ).not.toThrow()
    expect(repo.listAgentProfiles()[0]?.model).toBe('gpt-5.6-sol')
  })

  it('refuses a rename onto another profile, and a blank one', () => {
    const repo = new Repo(openDatabase(':memory:'))
    repo.createAgentProfile({ name: 'Zed architect', vendor: 'claude', model: '', effort: 'high', persona: '' })
    const fast = repo.createAgentProfile({ name: 'Fast reviewer', vendor: 'codex', model: '', effort: 'low', persona: '' })

    expect(() =>
      repo.updateAgentProfile(fast.id, {
        name: 'zed architect',
        vendor: 'codex',
        model: '',
        effort: 'low',
        persona: '',
      }),
    ).toThrow()
    expect(() =>
      repo.updateAgentProfile(fast.id, { name: '  ', vendor: 'codex', model: '', effort: 'low', persona: '' }),
    ).toThrow(/name/)
    // The failed edits changed nothing.
    expect(repo.listAgentProfiles().map((p) => p.name)).toEqual(['Fast reviewer', 'Zed architect'])
  })

  it('refuses an edit to a profile that is gone', () => {
    // A roster open in one window while the row is deleted in another. Silent
    // success would report an edit that never landed.
    const repo = new Repo(openDatabase(':memory:'))
    expect(() =>
      repo.updateAgentProfile('missing', {
        name: 'Anything',
        vendor: 'claude',
        model: '',
        effort: 'high',
        persona: '',
      }),
    ).toThrow(/no such profile/)
  })
})
