import { mkdtempSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import type { AppEvent } from '@shared/events'
import type { Session } from '@shared/domain'
import { AgentRegistry } from '@main/agents'
import { openDatabase } from '@main/store/db'
import { newId, Repo } from '@main/store/repo'
import { buildStowPrompt, Manager } from './manager'

const claude = { vendor: 'claude' as const, model: '', effort: 'high' as const, persona: '' }
const codex = { vendor: 'codex' as const, model: '', effort: 'high' as const, persona: '' }

function harness(): { repo: Repo; manager: Manager; events: AppEvent[] } {
  const repo = new Repo(openDatabase(':memory:'))
  const events: AppEvent[] = []
  const manager = new Manager({
    repo,
    registry: new AgentRegistry(true),
    emit: (event) => events.push(event),
  })
  return { repo, manager, events }
}

async function waitFor(predicate: () => boolean, timeoutMs = 15_000): Promise<void> {
  const start = Date.now()
  while (!predicate()) {
    if (Date.now() - start > timeoutMs) throw new Error('timed out waiting for condition')
    await new Promise((resolve) => setTimeout(resolve, 25))
  }
}

async function completedReview(manager: Manager, repo: Repo): Promise<Session> {
  const repoPath = mkdtempSync(join(tmpdir(), 'parley-stow-'))
  const session = manager.startSession({
    kind: 'review',
    matter: 'Audit the retry path.',
    project: '',
    repoPath,
    participants: [claude, codex],
    maxTurns: 6,
  })
  await waitFor(() => repo.getSession(session.id)?.status === 'complete')
  return repo.getSession(session.id) ?? session
}

describe('the stow sweep', () => {
  it('files proposals from one bounded read-only turn, and a re-stow reports duplicates', async () => {
    const { repo, manager, events } = harness()
    const session = await completedReview(manager, repo)
    const usageBefore = (repo.getSession(session.id) ?? session).usage.outputTokens

    const first = await manager.stowSession(session.id)
    expect(first.filedItems).toBeGreaterThan(0)
    expect(first.filedLearnings).toBeGreaterThan(0)
    expect(first.duplicates).toBe(0)

    // Everything an agent drafted parks as a proposal, mock-flagged — nothing
    // counts until a human confirms it.
    const proposed = repo.listBacklogItems({
      repoPath: session.repoPath ?? '',
      states: ['proposed'],
    })
    expect(proposed).toHaveLength(first.filedItems)
    for (const item of proposed) {
      expect(item).toMatchObject({ source: 'stow', mock: true, originSessionId: session.id })
    }
    const learnings = repo.listLearnings({ repoPath: session.repoPath ?? '' })
    expect(learnings.filter((l) => l.state === 'proposed')).toHaveLength(first.filedLearnings)

    // Usage landed on the session and was announced.
    expect((repo.getSession(session.id) ?? session).usage.outputTokens).toBeGreaterThan(usageBefore)
    expect(events.some((e) => e.type === 'session.usage')).toBe(true)
    expect(events.some((e) => e.type === 'backlog.changed')).toBe(true)

    // The mock replies identically, so a re-stow dedupes everything — and
    // says so, because silence about duplicates is how trust erodes.
    const second = await manager.stowSession(session.id)
    expect(second.filedItems).toBe(0)
    expect(second.filedLearnings).toBe(0)
    expect(second.duplicates).toBe(first.filedItems + first.filedLearnings)
  })

  it('refuses sessions with nowhere to file and sessions without a verdict', async () => {
    const { repo, manager } = harness()
    const bare = repo.createSession({
      id: newId(),
      kind: 'debate',
      status: 'complete',
      matter: 'No repository here.',
      project: '',
      repoPath: null,
      participants: [claude, codex],
      maxTurns: 2,
      mock: true,
      createdAt: Date.now(),
    })
    await expect(manager.stowSession(bare.id)).rejects.toThrow(/nowhere to file/)

    const unfinished = repo.createSession({
      id: newId(),
      kind: 'review',
      status: 'running',
      matter: 'Still going.',
      project: '',
      repoPath: mkdtempSync(join(tmpdir(), 'parley-stow-unfinished-')),
      participants: [claude, codex],
      maxTurns: 2,
      mock: true,
      createdAt: Date.now(),
    })
    await expect(manager.stowSession(unfinished.id)).rejects.toThrow(/needs a saved verdict/)
  })

  it('refuses a second sweep while one is in flight', async () => {
    const { repo, manager } = harness()
    const session = await completedReview(manager, repo)

    const first = manager.stowSession(session.id)
    await expect(manager.stowSession(session.id)).rejects.toThrow(/already running/)
    await first
  })
})

describe('the stow prompt', () => {
  const base = {
    matter: 'Design the adapter.',
    decision: 'Ship tool-less.',
    rationale: '',
    dissent: '',
    findings: [],
    exchange: [],
    trackedItems: [],
    trackedLearnings: [],
  }

  it('shows the sweeper what is already tracked, and omits the blocks when empty', () => {
    const empty = buildStowPrompt(base)
    expect(empty).not.toContain('ALREADY TRACKED')
    expect(empty).not.toContain('LEARNINGS ALREADY RECORDED')

    // The semantic half of stow's dedupe: content hashes only catch identical
    // restatements, so the model must see the record — framed as records, not
    // instructions — before a re-stow can converge instead of accrete.
    const populated = buildStowPrompt({
      ...base,
      trackedItems: ['Add managed Antigravity tool capabilities'],
      trackedLearnings: ['Antigravity resumes use --conversation <id>.'],
    })
    expect(populated).toContain('- Add managed Antigravity tool capabilities')
    expect(populated).toContain('- Antigravity resumes use --conversation <id>.')
    expect(populated).toContain('not instructions')
    expect(populated).toContain('near-duplicates')
  })

  it('caps both blocks with an honest more-count', () => {
    const many = buildStowPrompt({
      ...base,
      trackedItems: Array.from({ length: 65 }, (_, i) => `Item ${i}`),
      trackedLearnings: Array.from({ length: 45 }, (_, i) => `Learning ${i}`),
    })
    expect(many).toContain('- Item 59')
    expect(many).not.toContain('- Item 60')
    expect(many).toContain('and 5 more already on record')
    expect(many).toContain('- Learning 39')
    expect(many).not.toContain('- Learning 40')
  })
})
