import { describe, expect, it } from 'vitest'
import type { Session } from '@shared/domain'
import { groupSessions, recentProjects } from './sessionGroups'

const claude = { vendor: 'claude' as const, model: '', effort: 'high' as const, persona: '' }
const codex = { vendor: 'codex' as const, model: '', effort: 'high' as const, persona: '' }

function session(overrides: Partial<Session>): Session {
  return {
    id: Math.random().toString(36).slice(2),
    kind: 'debate',
    status: 'complete',
    matter: 'x',
    project: '',
    repoPath: null,
    participants: [claude, codex],
    maxTurns: 2,
    usage: {
      inputTokens: 0,
      cachedInputTokens: 0,
      outputTokens: 0,
      reasoningTokens: 0,
      costUsd: 0,
    },
    mock: false,
    createdAt: 1,
    endedAt: null,
    error: null,
    archivedAt: null,
    ...overrides,
  }
}

describe('grouping the session list', () => {
  const sessions = [
    session({ project: 'Atlas', repoPath: '/Users/x/Developer/atlas' }),
    session({ project: '', repoPath: '/Users/x/Developer/atlas' }),
    session({ project: 'Beacon', repoPath: null }),
    session({ project: 'Atlas', repoPath: '/Users/x/Developer/other' }),
  ]

  it('leaves the list alone when nothing is grouped', () => {
    const groups = groupSessions(sessions, 'none')
    expect(groups).toHaveLength(1)
    expect(groups[0]?.sessions).toEqual(sessions)
  })

  it('groups by project without reordering, newest group first', () => {
    const groups = groupSessions(sessions, 'project')
    // Group order follows first appearance — the thing you were just working
    // on must not be sorted away from the top.
    expect(groups.map((group) => group.title)).toEqual(['Atlas', 'Beacon', 'No project'])
    expect(groups[0]?.sessions).toHaveLength(2)
  })

  it('groups by repository, showing the short path', () => {
    const groups = groupSessions(sessions, 'repository')
    // shortPath's own rule: the last two segments, so two repositories that
    // share a parent stay distinguishable.
    expect(groups.map((group) => group.title)).toEqual([
      'Developer/atlas',
      'Developer/other',
      'No repository',
    ])
  })

  it('sinks the ungrouped bucket even when it appeared first', () => {
    const groups = groupSessions(
      [session({ project: '' }), session({ project: 'Atlas' })],
      'project',
    )
    expect(groups.map((group) => group.title)).toEqual(['Atlas', 'No project'])
  })

  it('keeps every session exactly once, whatever the grouping', () => {
    for (const grouping of ['none', 'project', 'repository'] as const) {
      const ids = groupSessions(sessions, grouping).flatMap((group) =>
        group.sessions.map((entry) => entry.id),
      )
      expect(new Set(ids).size).toBe(sessions.length)
    }
  })
})

describe('recent projects', () => {
  it('offers each project once, most recent first', () => {
    expect(
      recentProjects([
        session({ project: 'Atlas' }),
        session({ project: '  ' }),
        session({ project: 'Beacon' }),
        session({ project: 'Atlas' }),
      ]),
    ).toEqual(['Atlas', 'Beacon'])
  })

  it('caps the list so a suggestion never becomes a scroll', () => {
    const many = Array.from({ length: 30 }, (_, index) => session({ project: `p${index}` }))
    expect(recentProjects(many)).toHaveLength(8)
  })
})
