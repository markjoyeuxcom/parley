import { mkdtempSync, symlinkSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import type { BacklogEvent, BacklogItemState } from '@shared/domain'
import { canonicalRepoPath } from '@main/util/repoPath'
import { openDatabase } from './db'
import { Repo } from './repo'

function freshRepo(): Repo {
  return new Repo(openDatabase(':memory:'))
}

function fileItem(
  repo: Repo,
  overrides: Partial<Parameters<Repo['fileBacklogItem']>[0]> = {},
): ReturnType<Repo['fileBacklogItem']> {
  return repo.fileBacklogItem({
    repoPath: '/tmp/example-repo',
    title: 'The retry ceiling is not surfaced',
    detail: 'Callers cannot tell a give-up from a success.',
    source: 'review-finding',
    mock: true,
    ...overrides,
  })
}

/** The trail must always reproduce the column: last state-kind event wins. */
function foldState(events: BacklogEvent[]): BacklogItemState | null {
  let state: BacklogItemState | null = null
  for (const event of events) {
    if (event.kind !== 'resighted') state = event.kind
  }
  return state
}

describe('backlog items', () => {
  it('files deterministic sources as open, with the trail starting at the initial state', () => {
    const repo = freshRepo()
    const { item, resighted } = fileItem(repo)

    expect(resighted).toBe(false)
    expect(item.state).toBe('open')
    expect(item.mock).toBe(true)
    const events = repo.listBacklogEvents(item.id)
    expect(events).toHaveLength(1)
    expect(events[0]).toMatchObject({ kind: 'open', source: 'pipeline' })
  })

  it('a live collision resights the existing item rather than filing or vanishing', () => {
    const repo = freshRepo()
    const first = fileItem(repo)
    const second = fileItem(repo, { source: 'stow', state: 'proposed' })

    expect(second.resighted).toBe(true)
    expect(second.item.id).toBe(first.item.id)
    // The live item keeps its state; the trail records the re-raising.
    expect(second.item.state).toBe('open')
    const events = repo.listBacklogEvents(first.item.id)
    expect(events.at(-1)).toMatchObject({ kind: 'resighted', source: 'stow' })
    expect(repo.listBacklogItems()).toHaveLength(1)
  })

  it('a terminal item never blocks a genuine recurrence from filing fresh', () => {
    const repo = freshRepo()
    const first = fileItem(repo)
    repo.transitionBacklogItem(first.item.id, 'dropped', { source: 'human', note: 'Not now.' })

    const again = fileItem(repo)
    expect(again.resighted).toBe(false)
    expect(again.item.id).not.toBe(first.item.id)
    expect(repo.listBacklogItems({ states: ['open'] })).toHaveLength(1)
    expect(repo.listBacklogItems()).toHaveLength(2)
  })

  it('walks the legal lifecycle, requires a plan to plan, and clears it on reopen', () => {
    const repo = freshRepo()
    const { item } = fileItem(repo, { state: 'proposed', source: 'stow' })

    const opened = repo.transitionBacklogItem(item.id, 'open', { source: 'human' })
    expect(opened.state).toBe('open')

    expect(() =>
      repo.transitionBacklogItem(item.id, 'planned', { source: 'human' }),
    ).toThrow(/requires the plan id/)
    const planned = repo.transitionBacklogItem(item.id, 'planned', {
      source: 'human',
      planId: 'plan-1',
    })
    expect(planned.planId).toBe('plan-1')

    // A dead plan must not keep its claim: reopening detaches the item, or a
    // later retry of plan-1 completing would closure-propose an item that was
    // re-targeted at plan-2 in the meantime.
    const reopened = repo.transitionBacklogItem(item.id, 'open', { source: 'human' })
    expect(reopened.planId).toBeNull()

    const replanned = repo.transitionBacklogItem(item.id, 'planned', {
      source: 'human',
      planId: 'plan-2',
    })
    const proposed = repo.transitionBacklogItem(replanned.id, 'closure-proposed', {
      source: 'pipeline',
      note: 'Plan plan-2 completed.',
    })
    expect(proposed.state).toBe('closure-proposed')
    const done = repo.transitionBacklogItem(item.id, 'done', { source: 'human' })
    expect(done.state).toBe('done')

    expect(() => repo.transitionBacklogItem(item.id, 'open', { source: 'human' })).toThrow(
      /done backlog item cannot become open/,
    )
  })

  it('an open item can close as done directly — verified work is not a drop', () => {
    const repo = freshRepo()
    const { item } = fileItem(repo, { state: 'proposed', source: 'stow' })
    repo.transitionBacklogItem(item.id, 'open', { source: 'human' })

    // The foreman's "already landed, close as verified" advice — or work done
    // by hand outside Parley — needs this arc; `dropped` would record
    // "won't do" against work that was in fact done.
    const done = repo.transitionBacklogItem(item.id, 'done', {
      source: 'human',
      note: 'Closed from the board as already done.',
    })
    expect(done.state).toBe('done')
    expect(() => repo.transitionBacklogItem(item.id, 'open', { source: 'human' })).toThrow(
      /done backlog item cannot become open/,
    )
  })

  it('the event trail always folds to the state column', () => {
    const repo = freshRepo()
    const { item } = fileItem(repo, { state: 'proposed', source: 'stow' })
    repo.transitionBacklogItem(item.id, 'open', { source: 'human' })
    fileItem(repo, { state: 'proposed', source: 'stow' }) // resight — must not disturb the fold
    repo.transitionBacklogItem(item.id, 'planned', { source: 'human', planId: 'p' })
    repo.transitionBacklogItem(item.id, 'closure-proposed', { source: 'pipeline' })
    repo.transitionBacklogItem(item.id, 'open', { source: 'human' })
    repo.transitionBacklogItem(item.id, 'dropped', { source: 'human' })

    const current = repo.getBacklogItem(item.id)
    expect(foldState(repo.listBacklogEvents(item.id))).toBe(current?.state)
    expect(current?.state).toBe('dropped')
  })

  it('validates blockers: existence, same repository, no self, no cycles — and dedupes', () => {
    const repo = freshRepo()
    const a = fileItem(repo, { title: 'A' }).item
    const b = fileItem(repo, { title: 'B' }).item
    const c = fileItem(repo, { title: 'C' }).item
    const other = fileItem(repo, { title: 'Elsewhere', repoPath: '/tmp/other-repo' }).item

    expect(() => repo.setBacklogBlockedBy(a.id, ['missing'])).toThrow(/no such blocking item/)
    expect(() => repo.setBacklogBlockedBy(a.id, [a.id])).toThrow(/cannot block itself/)
    expect(() => repo.setBacklogBlockedBy(a.id, [other.id])).toThrow(/same repository/)

    repo.setBacklogBlockedBy(b.id, [a.id])
    repo.setBacklogBlockedBy(c.id, [b.id])
    expect(() => repo.setBacklogBlockedBy(a.id, [c.id])).toThrow(/cycle/)

    const updated = repo.setBacklogBlockedBy(a.id, [])
    expect(updated.blockedBy).toEqual([])
    expect(repo.setBacklogBlockedBy(c.id, [b.id, b.id]).blockedBy).toEqual([b.id])
  })

  it('canonicalises repo paths so a symlink or trailing slash cannot fork a backlog', () => {
    const repo = freshRepo()
    const real = mkdtempSync(join(tmpdir(), 'parley-backlog-real-'))
    const link = join(tmpdir(), `parley-backlog-link-${Date.now()}`)
    symlinkSync(real, link)

    fileItem(repo, { repoPath: `${real}/` })
    const viaLink = fileItem(repo, { repoPath: link })

    expect(viaLink.resighted).toBe(true)
    expect(repo.listBacklogItems({ repoPath: real })).toHaveLength(1)
    expect(repo.listBacklogItems({ repoPath: link })).toHaveLength(1)
    expect(repo.distinctBacklogRepos()).toEqual([canonicalRepoPath(real)])
  })
})

describe('learnings', () => {
  it('stow files proposed, manual files confirmed, and exact live duplicates are reported', () => {
    const repo = freshRepo()
    const stowed = repo.fileLearning({
      repoPath: '/tmp/example-repo',
      text: 'The suite is slow under Rosetta; run it natively.',
      source: 'stow',
      mock: true,
    })
    expect(stowed.learning.state).toBe('proposed')
    expect(stowed.duplicate).toBe(false)

    const manual = repo.fileLearning({
      repoPath: '/tmp/example-repo',
      text: 'Deploys happen from CI only.',
      source: 'manual',
      mock: false,
    })
    expect(manual.learning.state).toBe('confirmed')

    const dupe = repo.fileLearning({
      repoPath: '/tmp/example-repo/',
      text: 'The suite is slow under Rosetta; run it natively.',
      source: 'stow',
      mock: true,
    })
    expect(dupe.duplicate).toBe(true)
    expect(repo.listLearnings()).toHaveLength(2)
  })

  it('confirms and retires along the legal path only', () => {
    const repo = freshRepo()
    const { learning } = repo.fileLearning({
      repoPath: '/tmp/example-repo',
      text: 'Ledger identities are content-addressed.',
      source: 'stow',
      mock: true,
    })

    const confirmed = repo.transitionLearning(learning.id, 'confirmed')
    expect(confirmed.state).toBe('confirmed')
    const retired = repo.transitionLearning(learning.id, 'retired')
    expect(retired.state).toBe('retired')
    expect(() => repo.transitionLearning(learning.id, 'confirmed')).toThrow(
      /retired learning cannot become confirmed/,
    )
    // Retired entries stop blocking refiles: the same text files fresh.
    const again = repo.fileLearning({
      repoPath: '/tmp/example-repo',
      text: 'Ledger identities are content-addressed.',
      source: 'manual',
      mock: false,
    })
    expect(again.duplicate).toBe(false)
  })
})

describe('ingestion replay vs recurrence', () => {
  it('a same-session replay of a closed item is silently idempotent', () => {
    const repo = freshRepo()
    const { item } = fileItem(repo, { originSessionId: 'session-origin-1' })
    repo.transitionBacklogItem(item.id, 'done', { source: 'human', note: 'Landed elsewhere.' })
    const trailBefore = repo.listBacklogEvents(item.id).length

    // The startup back-sweep replays the same session's ingestion after every
    // relaunch. Before the same-origin carve-out this re-filed the finding as
    // a fresh open item every time — closure resurrected on restart, forever.
    const replay = fileItem(repo, { originSessionId: 'session-origin-1' })
    expect(replay.resighted).toBe(true)
    expect(replay.item.id).toBe(item.id)
    expect(repo.listBacklogItems({ repoPath: '/tmp/example-repo' })).toHaveLength(1)
    // Nothing new was observed: the settled trail is not stamped either.
    expect(repo.listBacklogEvents(item.id)).toHaveLength(trailBefore)
  })

  it('a different session re-observing the same content is a genuine recurrence', () => {
    const repo = freshRepo()
    const { item } = fileItem(repo, { originSessionId: 'session-origin-1' })
    repo.transitionBacklogItem(item.id, 'done', { source: 'human' })

    const recurred = fileItem(repo, { originSessionId: 'session-origin-2' })
    expect(recurred.resighted).toBe(false)
    expect(recurred.item.id).not.toBe(item.id)
    expect(recurred.item.state).toBe('open')

    // And the second session's own replays are idempotent against its copy,
    // even after that copy is dropped.
    repo.transitionBacklogItem(recurred.item.id, 'dropped', { source: 'human' })
    const replay = fileItem(repo, { originSessionId: 'session-origin-2' })
    expect(replay.resighted).toBe(true)
    expect(replay.item.id).toBe(recurred.item.id)
  })

  it('an item with no origin session keeps the old semantics: terminal never blocks fresh', () => {
    const repo = freshRepo()
    const { item } = fileItem(repo, { originSessionId: null })
    repo.transitionBacklogItem(item.id, 'dropped', { source: 'human' })
    const again = fileItem(repo, { originSessionId: null })
    expect(again.resighted).toBe(false)
    expect(again.item.id).not.toBe(item.id)
  })
})
