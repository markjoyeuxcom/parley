import { execFileSync } from 'node:child_process'
import { mkdtempSync, readFileSync, symlinkSync, unlinkSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import {
  isGreenfield,
  missingExpectedPaths,
  pathsOutsideScope,
  alignAudit,
  findingTexts,
  parseAudit,
  reviewerConfig,
  parsePlan,
  parseMutations,
  parseReview,
  summariseMutations,
  judgeMutation,
  milestoneVerdict,
  parseMutationRepairs,
  structuralConcerns,
  summariseTests,
  withMutationApplied,
  readTree,
  emptyTree,
  incrementalDelta,
  preExistingUntouched,
  renderDiffForReview,
  treeUnchanged,
  type TreeFileSnapshot,
  type TreeState,
  PLANNING_CONVERSATION,
} from './pipeline'
import { LoopConfigError, validateExitCommand } from './loop'
import type { MutationResult, TestResult } from '@shared/domain'
import { auditPrompt, planPrompt, reviewDiffPrompt } from '@shared/protocol'

describe('the planning conversation, declared', () => {
  it('speaks three read-only stages with the gates reality has', () => {
    // Consulted by speak and clarificationOf, pinned here: the planner's two
    // turns share one resumed thread, the audit is a fresh counterpart, and
    // only the planner's stages may park on a human question.
    expect(PLANNING_CONVERSATION.drafting).toEqual({
      status: 'drafting',
      actor: 'planner',
      resumed: true,
      gate: 'clarification',
    })
    expect(PLANNING_CONVERSATION.auditing).toEqual({
      status: 'auditing',
      actor: 'auditor',
      resumed: false,
      gate: 'none',
    })
    expect(PLANNING_CONVERSATION.correcting).toEqual({
      status: 'correcting',
      actor: 'planner',
      resumed: true,
      gate: 'clarification',
    })
  })
})

describe('parsePlan', () => {
  it('reads milestones in order', () => {
    const text = [
      '```json',
      JSON.stringify({
        title: 'Bound the retry path',
        milestones: [
          { title: 'Add a cap', intent: 'stop the spin', expectedPaths: ['src/net.ts'], testCommand: 'npm test' },
          { title: 'Cover it', intent: 'assert the terminal error', expectedPaths: [], testCommand: 'npm test' },
        ],
      }),
      '```',
    ].join('\n')

    const plan = parsePlan(text)
    expect(plan?.title).toBe('Bound the retry path')
    expect(plan?.milestones).toHaveLength(2)
    expect(plan?.milestones[0]?.expectedPaths).toEqual(['src/net.ts'])
  })

  it('skips milestones with no title', () => {
    const text = '```json\n{"milestones":[{"intent":"nameless"},{"title":"real"}]}\n```'
    expect(parsePlan(text)?.milestones).toHaveLength(1)
  })

  it('returns null when there is nothing executable', () => {
    expect(parsePlan('prose only')).toBeNull()
    expect(parsePlan('```json\n{"milestones":[]}\n```')).toBeNull()
    expect(parsePlan('```json\n{"milestones":"nope"}\n```')).toBeNull()
  })

  it('ignores non-string entries in expectedPaths', () => {
    const text = '```json\n{"milestones":[{"title":"x","expectedPaths":["a.ts",7,null,"b.ts"]}]}\n```'
    expect(parsePlan(text)?.milestones[0]?.expectedPaths).toEqual(['a.ts', 'b.ts'])
  })
})

describe('parseAudit', () => {
  it('reads dispositions keyed by milestone index', () => {
    const text = [
      '```json',
      JSON.stringify({
        verdict: 'needs-changes',
        dispositions: [
          { milestone: 0, disposition: 'accept', note: 'fine' },
          { milestone: 1, disposition: 'reject', note: 'file does not exist' },
        ],
        blockingConcerns: ['no migration step'],
      }),
      '```',
    ].join('\n')

    const audit = parseAudit(text)
    expect(audit?.verdict).toBe('needs-changes')
    expect(audit?.dispositions[1]?.disposition).toBe('reject')
    expect(audit?.blockingConcerns).toEqual(['no migration step'])
  })

  it('defaults an unrecognised disposition to revise, not accept', () => {
    // Erring toward accept would let a malformed audit wave a milestone through.
    const text = '```json\n{"dispositions":[{"milestone":0,"disposition":"looks-ok"}]}\n```'
    expect(parseAudit(text)?.dispositions[0]?.disposition).toBe('revise')
  })

  it('defaults an unrecognised verdict to needs-changes, not sound', () => {
    expect(parseAudit('```json\n{"verdict":"perfect"}\n```')?.verdict).toBe('needs-changes')
  })

  it('drops dispositions with a non-integer milestone index', () => {
    const text = '```json\n{"dispositions":[{"milestone":"first"},{"milestone":-1},{"milestone":2}]}\n```'
    expect(parseAudit(text)?.dispositions).toHaveLength(1)
  })
})

describe('parseReview', () => {
  it('reads a pass', () => {
    const review = parseReview(
      '```json\n{"passed":true,"blocking":[],"notes":[],"note":"scope matches"}\n```',
    )
    expect(review?.passed).toBe(true)
    expect(review?.note).toBe('scope matches')
  })

  it('reads a fail with blocking problems', () => {
    const review = parseReview(
      '```json\n{"passed":false,"blocking":["deleted a test"],"note":"no"}\n```',
    )
    expect(review?.passed).toBe(false)
    expect(findingTexts(review?.blocking ?? [])).toEqual(['deleted a test'])
  })

  it('refuses to pass a milestone whose review names a blocking problem', () => {
    // The failure this exists for: on three consecutive milestones the reviewer
    // found a real defect, wrote it down, and set passed:true. The flag is not
    // trusted against the reviewer's own findings.
    const review = parseReview(
      '```json\n{"passed":true,"blocking":["a hardcoded snapshot would pass this suite"],"note":"fine"}\n```',
    )
    expect(review?.passed).toBe(false)
    expect(review?.blocking).toHaveLength(1)
  })

  it('lets notes pass, because taste must not block', () => {
    const review = parseReview(
      '```json\n{"passed":true,"blocking":[],"notes":["I would have named it differently"],"note":"good"}\n```',
    )
    expect(review?.passed).toBe(true)
    expect(findingTexts(review?.notes ?? [])).toEqual(['I would have named it differently'])
  })

  it('never sends notes to remediation', () => {
    const review = parseReview(
      '```json\n{"passed":false,"blocking":["real defect"],"notes":["style nit"],"note":"n"}\n```',
    )
    // `blocking` is what becomes the remediation brief. A round told to fix what
    // was named and nothing else must not also be handed taste.
    expect(findingTexts(review?.blocking ?? [])).toEqual(['real defect'])
    expect(findingTexts(review?.blocking ?? [])).not.toContain('style nit')
  })

  it('keeps the reference when the reviewer points at code', () => {
    const review = parseReview(
      [
        '```json',
        JSON.stringify({
          passed: false,
          blocking: [
            {
              what: 'the retry ceiling is not surfaced',
              where: [{ path: 'src/retry.ts', line: 42, symbol: 'retry' }],
            },
          ],
          note: 'no',
        }),
        '```',
      ].join('\n'),
    )
    expect(review?.blocking[0]?.text).toBe('the retry ceiling is not surfaced')
    expect(review?.blocking[0]?.evidence).toEqual([
      { path: 'src/retry.ts', line: 42, symbol: 'retry', excerpt: '' },
    ])
  })

  it('still records a bare sentence, because the objection is the finding', () => {
    // Every reviewer wrote them this way until the contract grew somewhere to
    // put a reference. A run whose real objection was dropped for arriving as
    // prose would be worse off than before any of this existed.
    const review = parseReview(
      '```json\n{"passed":false,"blocking":["deleted a test"],"note":"no"}\n```',
    )
    expect(review?.blocking[0]).toEqual({ text: 'deleted a test', evidence: [] })
  })

  it('drops a reference that cannot be opened, and keeps the finding', () => {
    // A path is the whole point; a line that is not a positive integer is
    // worse than no line, because it sends the next reader somewhere with
    // confidence. Neither is a reason to lose what the reviewer said.
    const review = parseReview(
      [
        '```json',
        JSON.stringify({
          passed: false,
          blocking: [
            {
              what: 'something is wrong',
              where: [{ line: 12 }, { path: 'src/a.ts', line: -3 }, { path: 'src/b.ts', line: 1.5 }],
            },
          ],
          note: 'no',
        }),
        '```',
      ].join('\n'),
    )
    expect(review?.blocking[0]?.text).toBe('something is wrong')
    expect(review?.blocking[0]?.evidence).toEqual([
      { path: 'src/a.ts', line: null, symbol: '', excerpt: '' },
      { path: 'src/b.ts', line: null, symbol: '', excerpt: '' },
    ])
  })

  it('treats the old single-list key as blocking', () => {
    // A model still emitting `concerns` has ignored the schema; an unclassified
    // problem is safer read as blocking than as a note.
    const review = parseReview(
      '```json\n{"passed":true,"concerns":["stale occupancy"],"note":"ok"}\n```',
    )
    expect(review?.passed).toBe(false)
    expect(findingTexts(review?.blocking ?? [])).toEqual(['stale occupancy'])
  })

  it('ignores blank and non-string entries', () => {
    const review = parseReview(
      '```json\n{"passed":true,"blocking":["","   ",7,null],"note":"ok"}\n```',
    )
    // Whitespace is not a finding, and must not fail a milestone by accident.
    expect(review?.blocking).toEqual([])
    expect(review?.passed).toBe(true)
  })

  it('returns null when passed is missing or not a boolean', () => {
    // The caller treats null as "no usable judgement" and fails the milestone,
    // so this must not coerce a truthy string into a pass.
    expect(parseReview('```json\n{"note":"looks fine"}\n```')).toBeNull()
    expect(parseReview('```json\n{"passed":"yes"}\n```')).toBeNull()
    expect(parseReview('prose')).toBeNull()
  })
})

describe('tree snapshots', () => {
  function gitRepo(): string {
    const dir = mkdtempSync(join(tmpdir(), 'parley-diff-'))
    const git = (...args: string[]): void => {
      execFileSync('git', args, { cwd: dir, stdio: 'ignore' })
    }
    git('init', '-q')
    git('config', 'user.email', 'test@example.invalid')
    git('config', 'user.name', 'test')
    writeFileSync(join(dir, 'seed.txt'), 'seed\n')
    git('add', '.')
    git('commit', '-qm', 'seed')
    return dir
  }

  it('reports no change when nothing happened between snapshots', async () => {
    const dir = gitRepo()
    const before = await readTree(dir)
    const after = await readTree(dir)
    expect(treeUnchanged(before, after)).toBe(true)
  })

  it('detects an edit to a tracked file', async () => {
    const dir = gitRepo()
    const before = await readTree(dir)
    writeFileSync(join(dir, 'seed.txt'), 'changed\n')
    expect(treeUnchanged(before, await readTree(dir))).toBe(false)
  })

  it('detects a new untracked file, which plain `git diff` misses', async () => {
    const dir = gitRepo()
    const before = await readTree(dir)
    writeFileSync(join(dir, 'added.ts'), 'export const x = 1\n')
    expect(treeUnchanged(before, await readTree(dir))).toBe(false)
  })

  it('detects a staged change, which plain `git diff` also misses', async () => {
    const dir = gitRepo()
    const before = await readTree(dir)
    writeFileSync(join(dir, 'staged.ts'), 'export const y = 2\n')
    execFileSync('git', ['add', 'staged.ts'], { cwd: dir, stdio: 'ignore' })
    expect(treeUnchanged(before, await readTree(dir))).toBe(false)
  })

  it('still reports no change when the tree was ALREADY dirty and nothing new happened', async () => {
    // The exact bug this replaced: a single pre-existing untracked file — an
    // exported report, a leftover from an earlier attempt — made the old
    // "is the tree empty?" check see changes and wave the milestone through.
    const dir = gitRepo()
    writeFileSync(join(dir, 'VERDICT-bff89618.md'), '# leftover\n')

    const before = await readTree(dir)
    const after = await readTree(dir)

    expect(before.paths).toContain('VERDICT-bff89618.md')
    expect(treeUnchanged(before, after)).toBe(true)
  })

  it('detects new work on top of an already-dirty tree', async () => {
    const dir = gitRepo()
    writeFileSync(join(dir, 'leftover.md'), 'old\n')
    const before = await readTree(dir)
    writeFileSync(join(dir, 'real-work.ts'), 'export const z = 3\n')
    expect(treeUnchanged(before, await readTree(dir))).toBe(false)
  })

  it('detects a modification to an existing untracked file', async () => {
    const dir = gitRepo()
    writeFileSync(join(dir, 'scratch.txt'), 'one\n')
    const before = await readTree(dir)
    writeFileSync(join(dir, 'scratch.txt'), 'one\ntwo\n')
    expect(treeUnchanged(before, await readTree(dir))).toBe(false)
  })

  it('never claims "unchanged" outside a git repository', async () => {
    // Otherwise every milestone in a non-git directory would fail.
    const dir = mkdtempSync(join(tmpdir(), 'parley-nogit-'))
    const before = await readTree(dir)
    expect(before.unknown).toBe(true)
    expect(treeUnchanged(before, await readTree(dir))).toBe(false)
  })
})

describe('renderDiffForReview', () => {
  function gitRepo(): string {
    const dir = mkdtempSync(join(tmpdir(), 'parley-render-'))
    const git = (...args: string[]): void => {
      execFileSync('git', args, { cwd: dir, stdio: 'ignore' })
    }
    git('init', '-q')
    git('config', 'user.email', 't@e.invalid')
    git('config', 'user.name', 't')
    writeFileSync(join(dir, 'seed.txt'), 'seed\n')
    git('add', '.')
    git('commit', '-qm', 'seed')
    return dir
  }

  it('tells the reviewer which paths predate the milestone', async () => {
    const dir = gitRepo()
    writeFileSync(join(dir, 'VERDICT-old.md'), 'leftover\n')
    const before = await readTree(dir)

    writeFileSync(join(dir, 'new-work.ts'), 'export const a = 1\n')
    const after = await readTree(dir)

    const rendered = renderDiffForReview(after, before)
    expect(rendered).toMatch(/NOT part of this milestone/)
    expect(rendered).toContain('VERDICT-old.md')
    expect(rendered).toContain('new-work.ts')
  })

  it('shows only the milestone edit to an already-modified tracked file', async () => {
    const dir = gitRepo()
    writeFileSync(join(dir, 'seed.txt'), 'dirty before\n')
    writeFileSync(join(dir, 'untouched.txt'), 'leftover\n')
    const before = await readTree(dir)

    writeFileSync(join(dir, 'seed.txt'), 'dirty after\n')
    const after = await readTree(dir)
    const delta = incrementalDelta(before, after)

    expect(delta).toContain('--- changed file: seed.txt ---')
    expect(delta).toContain('-dirty before')
    expect(delta).toContain('+dirty after')
    expect(delta).not.toContain('-seed')
    expect(preExistingUntouched(before, after)).toEqual(['untouched.txt'])
    const rendered = renderDiffForReview(after, before)
    // The untouched list may only name digest-verified paths — never the dirty
    // file this milestone edited.
    const untouchedSection = rendered.split('--- diffstat ---')[0]
    expect(untouchedSection).toContain('untouched.txt')
    expect(untouchedSection).not.toContain('seed.txt')
    // And the milestone's own part of that file is isolated in the delta layer,
    // while the combined git diff (labelled as combined) still carries full code.
    expect(rendered).toContain("--- this milestone's own changes to already-dirty paths ---")
    expect(rendered).toContain('+dirty after')
  })

  it('omits distant unchanged content from a dirty file milestone delta', async () => {
    const dir = gitRepo()
    const beforeLines = [
      'PREEXISTING-DISTANT-START',
      ...Array.from({ length: 8 }, (_, index) => `leading context ${index}`),
      'milestone target before',
      ...Array.from({ length: 8 }, (_, index) => `trailing context ${index}`),
      'PREEXISTING-DISTANT-END',
    ]
    writeFileSync(join(dir, 'seed.txt'), `${beforeLines.join('\n')}\n`)
    const before = await readTree(dir)

    const afterLines = beforeLines.map((line) =>
      line === 'milestone target before' ? 'milestone target after' : line,
    )
    writeFileSync(join(dir, 'seed.txt'), `${afterLines.join('\n')}\n`)
    const delta = incrementalDelta(before, await readTree(dir))

    expect(delta).toContain('-milestone target before')
    expect(delta).toContain('+milestone target after')
    expect(delta).not.toContain('PREEXISTING-DISTANT-START')
    expect(delta).not.toContain('PREEXISTING-DISTANT-END')
  })

  it('shows only the milestone edit to an already-present untracked file', async () => {
    const dir = gitRepo()
    writeFileSync(join(dir, 'scratch.txt'), 'before\n')
    const before = await readTree(dir)

    writeFileSync(join(dir, 'scratch.txt'), 'after\n')
    const delta = incrementalDelta(before, await readTree(dir))

    expect(delta).toContain('--- changed file: scratch.txt ---')
    expect(delta).toContain('-before')
    expect(delta).toContain('+after')
  })

  it('names an edit beyond the truncated snapshot instead of calling it untouched', async () => {
    const dir = gitRepo()
    const committed = `${'a'.repeat(7000)}\n`
    writeFileSync(join(dir, 'long.txt'), committed)
    execFileSync('git', ['add', 'long.txt'], { cwd: dir, stdio: 'ignore' })
    execFileSync('git', ['commit', '-qm', 'long file'], { cwd: dir, stdio: 'ignore' })

    writeFileSync(join(dir, 'long.txt'), `${committed.slice(0, 6500)}before${committed.slice(6506)}`)
    const before = await readTree(dir)
    writeFileSync(join(dir, 'long.txt'), `${committed.slice(0, 6500)}after!${committed.slice(6506)}`)
    const after = await readTree(dir)
    const rendered = renderDiffForReview(after, before)

    expect(rendered).toContain('--- changed file: long.txt ---')
    expect(rendered).toContain('(contents differ beyond the bounded snapshot)')
    expect(preExistingUntouched(before, after)).not.toContain('long.txt')
  })

  it('names an edit to a file larger than the bounded read threshold', async () => {
    const dir = gitRepo()
    const committed = `${'a'.repeat(50_000)}\n`
    writeFileSync(join(dir, 'large.txt'), committed)
    execFileSync('git', ['add', 'large.txt'], { cwd: dir, stdio: 'ignore' })
    execFileSync('git', ['commit', '-qm', 'large file'], { cwd: dir, stdio: 'ignore' })

    writeFileSync(join(dir, 'large.txt'), `${committed.slice(0, -2)}b\n`)
    const before = await readTree(dir)
    writeFileSync(join(dir, 'large.txt'), `${committed.slice(0, -2)}c\n`)
    const after = await readTree(dir)
    const rendered = renderDiffForReview(after, before)

    expect(rendered).toContain('--- changed file: large.txt ---')
    expect(rendered).toContain('(contents differ beyond the bounded snapshot)')
    expect(preExistingUntouched(before, after)).not.toContain('large.txt')
  })

  it('names a changed path beyond the forty-file content bound', async () => {
    const dir = gitRepo()
    for (let index = 0; index <= 40; index += 1) {
      writeFileSync(join(dir, `dirty-${String(index).padStart(2, '0')}.txt`), 'before\n')
    }
    const before = await readTree(dir)
    writeFileSync(join(dir, 'dirty-40.txt'), 'after\n')
    const after = await readTree(dir)
    const rendered = renderDiffForReview(after, before)

    expect(rendered).toContain('--- changed file: dirty-40.txt ---')
    expect(rendered).toContain('(contents differ beyond the bounded snapshot)')
    expect(preExistingUntouched(before, after)).not.toContain('dirty-40.txt')
  })

  it('reports a pre-existing tracked file removed by the milestone', async () => {
    const dir = gitRepo()
    writeFileSync(join(dir, 'seed.txt'), 'dirty before deletion\n')
    const before = await readTree(dir)

    unlinkSync(join(dir, 'seed.txt'))
    const rendered = renderDiffForReview(await readTree(dir), before)

    expect(rendered).toContain('--- removed file: seed.txt ---')
    expect(rendered).toContain('-dirty before deletion')
  })

  it('reports a pre-existing untracked file removed by the milestone', async () => {
    const dir = gitRepo()
    writeFileSync(join(dir, 'scratch.txt'), 'temporary\n')
    const before = await readTree(dir)

    unlinkSync(join(dir, 'scratch.txt'))
    const after = await readTree(dir)
    const rendered = renderDiffForReview(after, before)

    expect(rendered).toContain('--- removed file: scratch.txt ---')
    expect(rendered).toContain('-temporary')
    expect(preExistingUntouched(before, after)).toEqual([])
  })

  it('shows both sides of a staged rename', async () => {
    const dir = gitRepo()
    const before = await readTree(dir)
    execFileSync('git', ['mv', 'seed.txt', 'renamed.txt'], { cwd: dir, stdio: 'ignore' })
    const after = await readTree(dir)
    const rendered = renderDiffForReview(after, before)

    expect(after.paths).toEqual(['renamed.txt', 'seed.txt'])
    // Decomposed by git itself (--no-renames on the content diffs): the removal
    // and the addition both arrive with real content, not two lines of
    // content-free rename metadata.
    expect(rendered).toContain('deleted file mode')
    expect(rendered).toMatch(/b\/renamed\.txt/)
    expect(rendered).toContain('new file mode')
  })

  it('omits the caveat when the tree started clean', async () => {
    const dir = gitRepo()
    const before = await readTree(dir)
    writeFileSync(join(dir, 'only-work.ts'), 'export const a = 1\n')
    const rendered = renderDiffForReview(await readTree(dir), before)
    expect(rendered).not.toMatch(/NOT part of this milestone/)
    expect(rendered).toContain('--- new file: only-work.ts ---')
    expect(rendered).toContain('export const a = 1')
  })

  it('carries a deep edit to a large tracked file as real hunks, not a bounded shrug', async () => {
    const dir = gitRepo()
    // Far larger than the per-file snapshot bound: the evidence must come from
    // git's own diff, which has no per-file cap.
    const big = Array.from({ length: 3000 }, (_, i) => `line ${i}`).join('\n')
    writeFileSync(join(dir, 'big.txt'), `${big}\n`)
    execFileSync('git', ['add', 'big.txt'], { cwd: dir, stdio: 'ignore' })
    execFileSync('git', ['commit', '-qm', 'big'], { cwd: dir, stdio: 'ignore' })

    const before = await readTree(dir)
    writeFileSync(join(dir, 'big.txt'), `${big.replace('line 2500', 'line 2500 EDITED-DEEP')}\n`)
    const after = await readTree(dir)
    const rendered = renderDiffForReview(after, before)

    expect(rendered).toContain('EDITED-DEEP')
    expect(rendered).not.toMatch(/NOT part of this milestone[\s\S]*big\.txt/)
  })

  it('renders two separated edits as two hunks without attributing the lines between', async () => {
    const dir = gitRepo()
    const lines = Array.from({ length: 60 }, (_, i) => `stable ${i}`)
    writeFileSync(join(dir, 'seed.txt'), `${lines.join('\n')}\n`)
    const before = await readTree(dir)

    const edited = [...lines]
    edited[5] = 'stable 5 CHANGED-TOP'
    edited[54] = 'stable 54 CHANGED-BOTTOM'
    writeFileSync(join(dir, 'seed.txt'), `${edited.join('\n')}\n`)
    const after = await readTree(dir)
    const delta = incrementalDelta(before, after)

    expect(delta).toContain('+stable 5 CHANGED-TOP')
    expect(delta).toContain('+stable 54 CHANGED-BOTTOM')
    // The 40-odd untouched lines between the edits must not be rendered as
    // removed-and-readded — that attributes pre-existing code to the milestone.
    expect(delta).not.toContain('-stable 30')
    expect(delta).not.toContain('+stable 30')
    expect((delta.match(/@@ /g) ?? []).length).toBeGreaterThanOrEqual(2)
  })

  it('never files an unknown digest under NOT part of this milestone', () => {
    const snapshot = (over: Partial<TreeFileSnapshot>): TreeFileSnapshot => ({
      path: 'x.txt',
      text: null,
      truncated: false,
      exists: true,
      digest: null,
      digestKnown: false,
      headText: null,
      headTruncated: false,
      headExists: true,
      headDigest: null,
      headDigestKnown: true,
      ...over,
    })
    const state = (files: TreeFileSnapshot[]): TreeState => ({
      unknown: false,
      signature: 's',
      paths: files.map((f) => f.path),
      diffText: '',
      stagedText: '',
      statText: '',
      untracked: [],
      files,
    })
    // A failed git spawn leaves the digest unknown on both sides. Unknown must
    // read as "cannot say", never as "untouched" — the poisoned failure mode was
    // both sides reporting not-exists and comparing equal.
    const before = state([snapshot({})])
    const after = state([snapshot({})])
    expect(preExistingUntouched(before, after)).toEqual([])
  })

  it('keeps the adoption baseline reviewable', async () => {
    const dir = gitRepo()
    writeFileSync(join(dir, 'seed.txt'), 'adopt this\n')
    const after = await readTree(dir)

    expect(incrementalDelta(emptyTree(), after)).toContain('+adopt this')
  })
})

describe('pathsOutsideScope', () => {
  it('names changed paths the milestone never claimed', () => {
    // The real case: a milestone scoped to internal/ghforge, a tree that also
    // holds edits to internal/forge and a stray report. The scoped test command
    // never touches the latter two, and saying so is the whole point.
    const changed = [
      'internal/ghforge/',
      'internal/forge/capability.go',
      'internal/ghrepo/create.go',
      'VERDICT-bff89618.md',
    ]
    const expected = ['internal/ghforge/client.go', 'internal/ghforge/repo.go']

    expect(pathsOutsideScope(changed, expected)).toEqual([
      'internal/forge/capability.go',
      'internal/ghrepo/create.go',
      'VERDICT-bff89618.md',
    ])
  })

  it('treats an untracked directory as covering the files the plan named inside it', () => {
    // git reports `pkg/` for a new directory while the plan names `pkg/a.go`.
    expect(pathsOutsideScope(['pkg/'], ['pkg/a.go'])).toEqual([])
  })

  it('counts everything as unverified when the milestone declared no paths', () => {
    expect(pathsOutsideScope(['a.ts', 'b.ts'], [])).toEqual(['a.ts', 'b.ts'])
  })

  it('returns nothing when the tree is clean', () => {
    expect(pathsOutsideScope([], ['a.ts'])).toEqual([])
  })
})

describe('missingExpectedPaths', () => {
  it('names the paths the plan promised but the executor never created', () => {
    const dir = mkdtempSync(join(tmpdir(), 'parley-expect-'))
    writeFileSync(join(dir, 'present.go'), 'package x\n')
    expect(missingExpectedPaths(dir, ['present.go', 'internal/forge/kind.go'])).toEqual([
      'internal/forge/kind.go',
    ])
  })

  it('returns nothing when everything exists', () => {
    const dir = mkdtempSync(join(tmpdir(), 'parley-expect-'))
    writeFileSync(join(dir, 'a.go'), 'package a\n')
    expect(missingExpectedPaths(dir, ['a.go'])).toEqual([])
    expect(missingExpectedPaths(dir, [])).toEqual([])
  })
})

describe('validateExitCommand', () => {
  it('accepts a plain command and returns its argv', () => {
    expect(validateExitCommand('npm test')).toEqual(['npm', 'test'])
    expect(validateExitCommand('  go test ./pkg  ')).toEqual(['go', 'test', './pkg'])
  })

  it('refuses shell syntax rather than silently running a shell', () => {
    for (const command of ['npm test | tee log', 'npm test && echo ok', 'rm -rf $(pwd)', 'echo $HOME']) {
      expect(() => validateExitCommand(command), command).toThrow(LoopConfigError)
    }
  })

  it('explains why, so the message is actionable', () => {
    expect(() => validateExitCommand('a | b')).toThrow(/without a shell/i)
  })

  it('refuses an empty command', () => {
    expect(() => validateExitCommand('   ')).toThrow(/needs a command/i)
  })

  it('refuses unbalanced quotes', () => {
    expect(() => validateExitCommand('npm test "oops')).toThrow(LoopConfigError)
  })
})

describe('isGreenfield', () => {
  function bareRepo(): string {
    const dir = mkdtempSync(join(tmpdir(), 'parley-green-'))
    const git = (...args: string[]): void => {
      execFileSync('git', args, { cwd: dir, stdio: 'ignore' })
    }
    git('init', '-q')
    git('config', 'user.email', 't@e.invalid')
    git('config', 'user.name', 't')
    return dir
  }

  it('treats a freshly initialised repository as new', async () => {
    expect(await isGreenfield(bareRepo())).toBe(true)
  })

  it('still treats it as new when only untracked debris is present', async () => {
    // An interrupted first attempt leaves files behind. The project is still
    // new: there are no conventions to read and no paths to check against.
    const dir = bareRepo()
    writeFileSync(join(dir, 'scratch.txt'), 'x\n')
    expect(await isGreenfield(dir)).toBe(true)
  })

  it('treats a repository with tracked files as established', async () => {
    const dir = bareRepo()
    writeFileSync(join(dir, 'main.go'), 'package main\n')
    execFileSync('git', ['add', '.'], { cwd: dir, stdio: 'ignore' })
    expect(await isGreenfield(dir)).toBe(false)
  })

  it('counts tracked files, not commits', async () => {
    // Staged but never committed is still a codebase someone is working in.
    const dir = bareRepo()
    writeFileSync(join(dir, 'main.go'), 'package main\n')
    execFileSync('git', ['add', 'main.go'], { cwd: dir, stdio: 'ignore' })
    expect(await isGreenfield(dir)).toBe(false)
  })

  it('handles a plain directory that is not a repository', async () => {
    const empty = mkdtempSync(join(tmpdir(), 'parley-plain-'))
    expect(await isGreenfield(empty)).toBe(true)

    const withFiles = mkdtempSync(join(tmpdir(), 'parley-plain2-'))
    writeFileSync(join(withFiles, 'index.js'), '\n')
    expect(await isGreenfield(withFiles)).toBe(false)
  })

  it('ignores dotfiles when judging a plain directory', async () => {
    // An editor or tool config does not make a project.
    const dir = mkdtempSync(join(tmpdir(), 'parley-dot-'))
    writeFileSync(join(dir, '.editorconfig'), '\n')
    expect(await isGreenfield(dir)).toBe(true)
  })
})

describe('greenfield prompts', () => {
  it('tells the planner it is establishing conventions, not reading them', () => {
    const green = planPrompt('implementation', 'a 3D game', '/new', '', true)
    const brown = planPrompt('implementation', 'a change', '/repo', '', false)

    expect(green).toMatch(/establishing/i)
    expect(green).toMatch(/empty/i)
    expect(brown).toMatch(/Read enough of the codebase/i)
    expect(brown).not.toMatch(/establishing/i)
  })

  it('requires the first milestone to make verification runnable', () => {
    // Otherwise a plan can defer its own testability to milestone four.
    expect(planPrompt('implementation', 'x', '/new', '', true)).toMatch(
      /first milestone must scaffold/i,
    )
  })

  it('stops the auditor reporting every path as missing', () => {
    // The failure this exists to prevent: on an empty repo *no* named path
    // exists, so a literal audit rejects the entire plan for a non-defect.
    const green = auditPrompt('{}', '/new', true)
    const brown = auditPrompt('{}', '/repo', false)

    expect(green).toMatch(/do not report missing files/i)
    expect(brown).toMatch(/Do the named files exist/i)
    expect(brown).not.toMatch(/do not report missing files/i)
  })
})

describe('reviewDiffPrompt', () => {
  it('names every declared output that is still missing', () => {
    const prompt = reviewDiffPrompt(
      'Ship the cap',
      'Bound retries',
      'diff',
      'tests passed',
      [],
      '',
      ['src/net/client.ts', 'src/net/client.test.ts'],
    )

    expect(prompt).toMatch(/cannot pass/i)
    expect(prompt).toContain('src/net/client.ts')
    expect(prompt).toContain('src/net/client.test.ts')
  })
})

describe('summariseTests distinguishes four ways of not passing', () => {
  /**
   * A non-zero result can mean three different things that call for three
   * different responses, and the reviewer and executor read this text to decide
   * which. Told "FAILED", an executor changes the code — right for a real
   * failure, wrong for a crash, and actively misleading for a hang, where the
   * code may be correct and simply never returns.
   */
  const base = {
    command: 'tests/run.sh',
    exitCode: 0,
    signal: null as string | null,
    timedOut: false,
    startError: null,
    stdout: '6 test case(s), 0 failure(s)',
    stderr: '',
    durationMs: 3000,
    ranAt: 1,
  }

  it('reports a clean run as passed', () => {
    expect(summariseTests(base)).toContain('PASSED')
  })

  it('reports a command that never started as never started', () => {
    // The fourth way, and the only one where nothing about the code is in
    // question at all. Called FAILED it sends an executor to rewrite working
    // code — which is exactly what a host with no node on its PATH cost,
    // twice, in one run.
    const text = summariseTests({
      ...base,
      exitCode: -1,
      startError: 'spawn node ENOENT',
    })
    expect(text).toContain('NEVER RAN')
    expect(text).toContain('spawn node ENOENT')
    expect(text).not.toMatch(/FAILED/)
    // And it points at the machine rather than the diff.
    expect(text).toMatch(/outside what an edit can fix/i)
  })

  it('says nothing ran even when the exit code looks like a plain failure', () => {
    // A command can fail to start AND carry a conventional-looking code. The
    // start error is checked first because it is the stronger claim: not
    // "this went badly" but "this did not happen".
    const text = summariseTests({ ...base, exitCode: 127, startError: 'spawn npm ENOENT' })
    expect(text).toContain('NEVER RAN')
    expect(text).not.toContain('exit 127')
  })

  it('reports a real failure with its exit code', () => {
    const text = summariseTests({ ...base, exitCode: 1 })
    expect(text).toContain('FAILED (exit 1)')
    expect(text).not.toMatch(/DID NOT/)
  })

  it('reports a crash as a crash, not a failing test', () => {
    const text = summariseTests({ ...base, exitCode: -1, signal: 'SIGSEGV' })
    expect(text).toMatch(/DID NOT COMPLETE/)
    expect(text).toContain('SIGSEGV')
    expect(text).toMatch(/not a failing test/i)
  })

  it('reports a hang as a hang even though a timeout is also a SIGTERM', () => {
    // The ordering guard. Parley kills on timeout with SIGTERM, so a summariser
    // that checked `signal` first would describe a twenty-minute hang as an
    // external crash and send the reader hunting for what killed the process.
    const text = summariseTests({
      ...base,
      exitCode: -1,
      signal: 'SIGTERM',
      timedOut: true,
      durationMs: 20 * 60 * 1000,
    })
    expect(text).toMatch(/DID NOT FINISH/)
    expect(text).toMatch(/hang/i)
    expect(text).not.toContain('SIGTERM')
    expect(text).not.toMatch(/crash in the verification command/)
  })

  it('says plainly when there was no command to run', () => {
    // Distinct again from all of the above: nothing was attempted, so the
    // reviewer must weigh the diff without the benefit of a test result.
    expect(summariseTests(null)).toMatch(/nothing was run/i)
  })
})

describe('parseMutations', () => {
  it('reads a well-formed mutation', () => {
    const out = parseMutations([
      { file: 'src/a.ts', find: 'return derived()', replace: 'return 0', describes: 'hardcoded result' },
    ])
    expect(out).toHaveLength(1)
    expect(out[0]?.describes).toBe('hardcoded result')
  })

  it('drops a mutation that changes nothing', () => {
    // find === replace would apply cleanly, pass, and report a false negative:
    // the suite "caught" nothing because nothing broke.
    expect(parseMutations([{ file: 'a.ts', find: 'x', replace: 'x', describes: 'noop' }])).toEqual([])
  })

  it('drops entries with no file or no find text', () => {
    expect(
      parseMutations([
        { file: '', find: 'x', replace: 'y', describes: 'd' },
        { file: 'a.ts', find: '   ', replace: 'y', describes: 'd' },
        { file: 'a.ts', replace: 'y', describes: 'd' },
      ]),
    ).toEqual([])
  })

  it('survives junk without failing the whole plan', () => {
    // A malformed mutation is a missing check, which the review will notice. A
    // rejected plan over one bad entry is the worse trade.
    expect(parseMutations('not an array')).toEqual([])
    expect(parseMutations([null, 7, 'x'])).toEqual([])
  })

  it('caps the list, so a plan cannot ask for hundreds of test runs', () => {
    const many = Array.from({ length: 40 }, (_, i) => ({
      file: 'a.ts',
      find: `find${i}`,
      replace: `broken${i}`,
      describes: 'd',
    }))
    expect(parseMutations(many).length).toBeLessThanOrEqual(10)
  })
})

describe('summariseMutations', () => {
  it('says plainly when a break went undetected', () => {
    const text = summariseMutations([
      { describes: 'hardcoded winner', file: 'game.gd', caught: false, skipped: '', skipKind: '' as const, exitCode: 0 },
    ])
    expect(text).toMatch(/SURVIVED/)
    expect(text).toMatch(/nothing in it pins this/i)
  })

  it('distinguishes caught, survived and not-checked', () => {
    const text = summariseMutations([
      { describes: 'a', file: 'x', caught: true, skipped: '', skipKind: '' as const, exitCode: 1 },
      { describes: 'b', file: 'y', caught: false, skipped: '', skipKind: '' as const, exitCode: 0 },
      {
        describes: 'c',
        file: 'z',
        caught: false,
        skipped: 'the text was not found',
        skipKind: 'no-test-command' as const,
        exitCode: null,
      },
    ])
    expect(text).toMatch(/CAUGHT — x/)
    expect(text).toMatch(/SURVIVED — y/)
    expect(text).toMatch(/NOT CHECKED — z/)
    // A skipped mutation must never read as a pass.
    expect(text).not.toMatch(/CAUGHT — z/)
  })

  it('is empty when nothing was declared, so the prompt omits the block', () => {
    expect(summariseMutations([])).toBe('')
  })
})

describe('withMutationApplied', () => {
  const scratch = (contents: string): { repo: string; file: string } => {
    const repo = mkdtempSync(join(tmpdir(), 'parley-mutate-'))
    writeFileSync(join(repo, 'game.gd'), contents, 'utf8')
    return { repo, file: join(repo, 'game.gd') }
  }
  const mutation = { file: 'game.gd', find: 'winner', replace: 'loser', describes: 'flip it' }

  it('shows the mutated text to the run, then puts the file back', async () => {
    const { repo, file } = scratch('func winner():\n\tpass\n')
    let seen = ''
    const outcome = await withMutationApplied(repo, mutation, async () => {
      seen = readFileSync(file, 'utf8')
      return 'ran'
    })
    expect(outcome).toEqual({ applied: true, result: 'ran' })
    expect(seen).toBe('func loser():\n\tpass\n')
    // The whole feature is untrustworthy if this line ever fails.
    expect(readFileSync(file, 'utf8')).toBe('func winner():\n\tpass\n')
  })

  it('puts the file back even when the run throws', async () => {
    const { repo, file } = scratch('func winner():\n')
    await expect(
      withMutationApplied(repo, mutation, async () => {
        throw new Error('test runner exploded')
      }),
    ).rejects.toThrow('test runner exploded')
    expect(readFileSync(file, 'utf8')).toBe('func winner():\n')
  })

  it('refuses a path that climbs out of the repository', async () => {
    const { repo } = scratch('func winner():\n')
    let ran = false
    const outcome = await withMutationApplied(
      repo,
      { ...mutation, file: '../../etc/hosts' },
      async () => {
        ran = true
        return null
      },
    )
    expect(outcome).toEqual({ applied: false, reason: 'that path resolves outside the repository' })
    expect(ran).toBe(false)
  })

  it('refuses an edit that would match more than once', async () => {
    const { repo, file } = scratch('winner = 1\nwinner = 2\n')
    const outcome = await withMutationApplied(repo, mutation, async () => null)
    expect(outcome.applied).toBe(false)
    if (!outcome.applied) expect(outcome.reason).toMatch(/appears 2 times/)
    expect(readFileSync(file, 'utf8')).toBe('winner = 1\nwinner = 2\n')
  })

  it('refuses an edit that matches nothing, rather than silently passing', async () => {
    const { repo } = scratch('func draw():\n')
    const outcome = await withMutationApplied(repo, mutation, async () => null)
    expect(outcome).toEqual({ applied: false, reason: 'the text to replace was not found' })
  })

  it('refuses a file that is not there', async () => {
    const { repo } = scratch('func winner():\n')
    const outcome = await withMutationApplied(repo, { ...mutation, file: 'nope.gd' }, async () => null)
    expect(outcome).toEqual({ applied: false, reason: 'that file does not exist' })
  })
})

describe('judgeMutation', () => {
  const m = { describes: 'flip the winner', file: 'game.gd' }
  const ran = (exitCode: number): { applied: true; result: TestResult } => ({
    applied: true,
    result: {
      command: 'tests/run.sh',
      exitCode,
      signal: null,
      timedOut: false,
      startError: null,
      stdout: '',
      stderr: '',
      durationMs: 1,
      ranAt: 0,
    },
  })

  it('is caught only when the tests actually ran and failed', () => {
    expect(judgeMutation(m, ran(1))).toMatchObject({ caught: true, skipped: '', exitCode: 1 })
  })

  it('survives when the tests ran and still passed', () => {
    expect(judgeMutation(m, ran(0))).toMatchObject({ caught: false, skipped: '', exitCode: 0 })
  })

  // The three below are the false-green guards: a mutation that never really ran
  // must never be recorded as caught, because caught is what lets a milestone pass.
  it('does not count an unapplied mutation as caught', () => {
    const r = judgeMutation(m, { applied: false, reason: 'the text to replace was not found' })
    expect(r.caught).toBe(false)
    expect(r.skipped).toBe('the text to replace was not found')
  })

  it('does not count a mutation with no test command as caught', () => {
    const r = judgeMutation(m, { applied: true, result: null })
    expect(r.caught).toBe(false)
    expect(r.skipped).toMatch(/no verification command/)
  })

  // A suite that dies on any malformed input would otherwise "catch" every mutation
  // while checking nothing — the false green this whole stage exists to detect.
  it('does not credit a crash as catching the break', () => {
    const r = judgeMutation(m, {
      applied: true,
      result: { ...ran(139).result, signal: 'SIGSEGV' },
    })
    expect(r.caught).toBe(false)
    expect(r.skipKind).toBe('crashed')
    expect(r.skipped).toMatch(/SIGSEGV/)
  })

  it('does not credit a timeout as catching the break, though it arrives as SIGTERM', () => {
    const r = judgeMutation(m, {
      applied: true,
      result: { ...ran(143).result, signal: 'SIGTERM', timedOut: true },
    })
    expect(r.caught).toBe(false)
    expect(r.skipKind).toBe('crashed')
    expect(r.skipped).toMatch(/timed out/)
  })

  it('never reports both caught and skipped, which would read as a pass', () => {
    const outcomes = [
      ran(0),
      ran(1),
      { applied: true as const, result: null },
      { applied: false as const, reason: 'that file does not exist' },
      { applied: true as const, result: { ...ran(139).result, signal: 'SIGSEGV' } },
      { applied: true as const, result: { ...ran(143).result, signal: 'SIGTERM', timedOut: true } },
    ]
    for (const o of outcomes) {
      const r = judgeMutation(m, o)
      expect(r.caught && r.skipped !== '').toBe(false)
    }
  })
})

describe('structuralConcerns', () => {
  it('objects to checks that have no command to run them', () => {
    const found = structuralConcerns({
      testCommand: '  ',
      mutations: [{ file: 'a.gd', find: 'x', replace: 'y', describes: 'the win check' }],
    })
    expect(found).toHaveLength(1)
    expect(found[0]).toMatch(/no command to run/)
    expect(found[0]).toMatch(/only look like coverage/)
  })

  it('says nothing when the milestone is coherent', () => {
    expect(
      structuralConcerns({
        testCommand: 'tests/run.sh',
        mutations: [{ file: 'a.gd', find: 'x', replace: 'y', describes: 'the win check' }],
      }),
    ).toEqual([])
    expect(structuralConcerns({ testCommand: '', mutations: [] })).toEqual([])
  })
})

describe('parseMutationRepairs', () => {
  it('reads a corrected anchor', () => {
    const { repairs, impossible } = parseMutationRepairs(
      '{"repairs":[{"index":1,"find":"if winner:","replace":"if true:"}],"impossible":[]}',
    )
    expect(repairs.get(1)).toEqual({ find: 'if winner:', replace: 'if true:' })
    expect(impossible.size).toBe(0)
  })

  it('accepts a refusal as a real answer', () => {
    const { repairs, impossible } = parseMutationRepairs(
      '{"repairs":[],"impossible":[{"index":2,"why":"the win check was never written"}]}',
    )
    expect(repairs.size).toBe(0)
    expect(impossible.get(2)).toBe('the win check was never written')
  })

  it('drops a no-op edit, which would pass without checking anything', () => {
    const { repairs } = parseMutationRepairs(
      '{"repairs":[{"index":1,"find":"same","replace":"same"}]}',
    )
    expect(repairs.size).toBe(0)
  })

  it('ignores an out-of-range or unparseable index', () => {
    const { repairs } = parseMutationRepairs(
      '{"repairs":[{"index":0,"find":"a","replace":"b"},{"index":"x","find":"c","replace":"d"},{"index":99,"find":"e","replace":"f"}]}',
    )
    expect(repairs.size).toBe(0)
  })

  it('lets a repair win over a contradictory impossible for the same item', () => {
    const { repairs, impossible } = parseMutationRepairs(
      '{"repairs":[{"index":1,"find":"a","replace":"b"}],"impossible":[{"index":1,"why":"cannot"}]}',
    )
    expect(repairs.has(1)).toBe(true)
    expect(impossible.has(1)).toBe(false)
  })

  it('returns empty on junk rather than throwing', () => {
    expect(parseMutationRepairs('sorry, I could not do that').repairs.size).toBe(0)
  })
})

describe('summariseMutations, after a repair round', () => {
  it('marks an unapplied check as blocking, not as a harmless gap', () => {
    const text = summariseMutations([
      {
        describes: 'the win check',
        file: 'game.gd',
        caught: false,
        skipped: 'the re-anchored edit also failed: the text to replace was not found',
        skipKind: 'unapplied',
        exitCode: null,
      },
    ])
    expect(text).toMatch(/COULD NOT BE CHECKED \(blocking\)/)
  })

  it('still distinguishes a missing test command from an unapplied anchor', () => {
    const text = summariseMutations([
      { describes: 'a', file: 'x', caught: false, skipped: 'no command', skipKind: 'no-test-command', exitCode: null },
    ])
    expect(text).toMatch(/NOT CHECKED — x/)
    expect(text).not.toMatch(/blocking/)
  })
})

describe('milestoneVerdict', () => {
  const green = (): TestResult => ({
    command: 'tests/run.sh',
    exitCode: 0,
    signal: null,
    timedOut: false,
    startError: null,
    stdout: '',
    stderr: '',
    durationMs: 1,
    ranAt: 0,
  })
  const mut = (over: Partial<MutationResult>): MutationResult => ({
    describes: 'the win check',
    file: 'game.gd',
    caught: true,
    skipped: '',
    skipKind: '',
    exitCode: 1,
    ...over,
  })

  it('passes a green suite whose every declared break was caught', () => {
    const v = milestoneVerdict(green(), [mut({})])
    expect(v.testsPassed).toBe(true)
    expect(v.surviving).toEqual([])
  })

  it('fails when the suite is red, whatever the mutations say', () => {
    expect(milestoneVerdict({ ...green(), exitCode: 1 }, [mut({})]).testsPassed).toBe(false)
  })

  it('fails when a declared break went unnoticed', () => {
    const v = milestoneVerdict(green(), [mut({ caught: false, exitCode: 0 })])
    expect(v.testsPassed).toBe(false)
    expect(v.surviving).toHaveLength(1)
  })

  // The point of the repair round: one stale anchor is forgiven and retried, but a
  // check that still cannot be applied afterwards must not pass as verified.
  it('fails when a check could not be applied even after re-anchoring', () => {
    const v = milestoneVerdict(green(), [
      mut({ caught: false, skipped: 'the re-anchored edit also failed', skipKind: 'unapplied', exitCode: null }),
    ])
    expect(v.testsPassed).toBe(false)
    expect(v.unverifiable).toHaveLength(1)
  })

  it('does not fail on a missing test command, which is a plan defect not a code one', () => {
    const v = milestoneVerdict(null, [
      mut({ caught: false, skipped: 'no command', skipKind: 'no-test-command', exitCode: null }),
    ])
    expect(v.testsPassed).toBe(true)
    expect(v.notRunnable).toHaveLength(1)
  })

  // Each bucket is reported to the operator by name, so a filter that quietly
  // scoops up unrelated results would misdescribe what actually happened.
  it('sorts a mixed set into the right buckets and no others', () => {
    const v = milestoneVerdict(green(), [
      mut({ describes: 'caught' }),
      mut({ describes: 'survived', caught: false, exitCode: 0 }),
      mut({ describes: 'stale', caught: false, skipped: 'no match', skipKind: 'unapplied', exitCode: null }),
      mut({ describes: 'no command', caught: false, skipped: 'none', skipKind: 'no-test-command', exitCode: null }),
    ])
    expect(v.surviving.map((m) => m.describes)).toEqual(['survived'])
    expect(v.unverifiable.map((m) => m.describes)).toEqual(['stale'])
    expect(v.notRunnable.map((m) => m.describes)).toEqual(['no command'])
    expect(v.testsPassed).toBe(false)
  })

  it('fails when the suite crashed under a mutation, since that proved nothing', () => {
    const v = milestoneVerdict(green(), [
      mut({ caught: false, skipped: 'killed by SIGSEGV', skipKind: 'crashed', exitCode: 139 }),
    ])
    expect(v.testsPassed).toBe(false)
    expect(v.unverifiable).toHaveLength(1)
  })

  it('passes a milestone with no tests and no mutations, as before', () => {
    expect(milestoneVerdict(null, []).testsPassed).toBe(true)
  })
})

describe('withMutationApplied and symlinks', () => {
  it('refuses a repo-local symlink whose target is outside the repository', async () => {
    const outside = mkdtempSync(join(tmpdir(), 'parley-outside-'))
    const secret = join(outside, 'secret.txt')
    writeFileSync(secret, 'do not touch\n', 'utf8')

    const repo = mkdtempSync(join(tmpdir(), 'parley-symlink-'))
    // Lexically this is repo-local; only resolving it reveals where it goes.
    symlinkSync(secret, join(repo, 'innocent.gd'))

    let ran = false
    const outcome = await withMutationApplied(
      repo,
      { file: 'innocent.gd', find: 'do not touch', replace: 'touched', describes: 'escape' },
      async () => {
        ran = true
        return null
      },
    )
    expect(outcome).toEqual({ applied: false, reason: 'that path resolves outside the repository' })
    expect(ran).toBe(false)
    expect(readFileSync(secret, 'utf8')).toBe('do not touch\n')
  })

  it('still allows a symlink that stays inside the repository', async () => {
    const repo = mkdtempSync(join(tmpdir(), 'parley-symlink-ok-'))
    writeFileSync(join(repo, 'real.gd'), 'func winner():\n', 'utf8')
    symlinkSync(join(repo, 'real.gd'), join(repo, 'alias.gd'))

    const outcome = await withMutationApplied(
      repo,
      { file: 'alias.gd', find: 'winner', replace: 'loser', describes: 'inside' },
      async () => 'ran',
    )
    expect(outcome).toEqual({ applied: true, result: 'ran' })
    expect(readFileSync(join(repo, 'real.gd'), 'utf8')).toBe('func winner():\n')
  })
})

describe('alignAudit', () => {
  const d = (
    milestone: number,
    disposition: 'accept' | 'revise' | 'reject' = 'accept',
  ): { milestone: number; disposition: 'accept' | 'revise' | 'reject'; note: string } => ({
    milestone,
    disposition,
    note: 'n',
  })
  const parsed = (...dispositions: ReturnType<typeof d>[]): NonNullable<Parameters<typeof alignAudit>[0]> => ({
    verdict: 'needs-changes',
    dispositions,
    blockingConcerns: [],
  })

  it('leaves a 0-based reply untouched', () => {
    const { audit, note } = alignAudit(parsed(d(0), d(1), d(2)), 3)
    expect(audit?.dispositions.map((x) => x.milestone)).toEqual([0, 1, 2])
    expect(note).toBe('')
  })

  // The signature that cannot come from a 0-based reply: no index 0, the count
  // itself present, everything inside [1..count]. A REJECT shifted one milestone
  // late marks the wrong work rejected and lets the genuinely rejected work pass.
  it('realigns a provably 1-based reply and says so', () => {
    const { audit, note } = alignAudit(parsed(d(1, 'reject'), d(2), d(3)), 3)
    expect(audit?.dispositions.map((x) => x.milestone)).toEqual([0, 1, 2])
    expect(audit?.dispositions[0]?.disposition).toBe('reject')
    expect(note).toMatch(/numbered milestones from 1/)
  })

  it('realigns the single-milestone case', () => {
    const { audit } = alignAudit(parsed(d(1)), 1)
    expect(audit?.dispositions.map((x) => x.milestone)).toEqual([0])
  })

  it('does not shift an ambiguous reply that merely skips the first milestone', () => {
    // {1, 2} of 3 could be 0-based-missing-first or 1-based-missing-last; there is
    // no proof either way, so it is applied as written rather than guessed at.
    const { audit, note } = alignAudit(parsed(d(1), d(2)), 3)
    expect(audit?.dispositions.map((x) => x.milestone)).toEqual([1, 2])
    expect(note).toBe('')
  })

  it('discards an out-of-range disposition loudly instead of dropping it silently', () => {
    const { audit, note } = alignAudit(parsed(d(0), d(7)), 3)
    expect(audit?.dispositions.map((x) => x.milestone)).toEqual([0])
    expect(note).toMatch(/milestone 8 which does not exist/)
    expect(note).toMatch(/discarded rather than silently misapplied/)
  })

  it('passes null and empty through unchanged', () => {
    expect(alignAudit(null, 3)).toEqual({ audit: null, note: '' })
    const empty = parsed()
    expect(alignAudit(empty, 3).audit).toBe(empty)
  })
})

describe('reviewerConfig', () => {
  const configured = {
    vendor: 'claude' as const,
    model: 'opus',
    effort: 'high' as const,
    persona: 'terse',
  }

  it('passes an uncoerced config through untouched', () => {
    expect(reviewerConfig(configured, 'claude')).toBe(configured)
  })

  // The bug this pins: swapping only the vendor field carried a Claude model
  // name into the codex CLI. Effort and persona are vendor-neutral and survive;
  // the model is not, and the CLI must fall back to its own default.
  it('blanks the model when the vendor is swapped, keeping effort and persona', () => {
    expect(reviewerConfig(configured, 'codex')).toEqual({
      vendor: 'codex',
      model: '',
      effort: 'high',
      persona: 'terse',
    })
  })
})
