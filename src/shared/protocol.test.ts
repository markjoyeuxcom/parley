import { describe, expect, it } from 'vitest'
import {
  CORRECTION_CONTRACT,
  REVIEW_CONTRACT,
  adoptReviewPrompt,
  debatePrompt,
  remediationPrompt,
  debateStages,
  executePrompt,
  reviewStages,
  stagesFor,
} from './protocol'

describe('debateStages', () => {
  it('always opens with a position and closes with a convergence', () => {
    for (const turns of [2, 3, 4, 6, 9, 12]) {
      const stages = debateStages(turns)
      expect(stages[0]?.id, `turns=${turns}`).toBe('open')
      expect(stages[0]?.seat).toBe(0)
      expect(stages.at(-1)?.id, `turns=${turns}`).toBe('converge')
    }
  })

  it('produces exactly the requested number of turns', () => {
    for (const turns of [2, 3, 4, 5, 6, 8, 12]) {
      expect(debateStages(turns), `turns=${turns}`).toHaveLength(turns)
    }
  })

  it('alternates seats so nobody speaks twice in a row', () => {
    const stages = debateStages(8)
    for (let i = 1; i < stages.length; i += 1) {
      expect(stages[i]?.seat, `stage ${i}`).not.toBe(stages[i - 1]?.seat)
    }
  })

  it('still yields a complete exchange at the minimum length', () => {
    const stages = debateStages(2)
    expect(stages.map((s) => s.id)).toEqual(['open', 'converge'])
    expect(stages[1]?.seat).toBe(1)
  })

  it('gives every stage a distinct id, since ids key the transcript', () => {
    const ids = debateStages(12).map((s) => s.id)
    expect(new Set(ids).size).toBe(ids.length)
  })
})

describe('reviewStages', () => {
  it('maps, audits, cross-examines, then reconciles', () => {
    expect(reviewStages().map((s) => s.id)).toEqual(['map', 'audit', 'crossAudit', 'reconcile'])
  })

  it('has the cross-examination come from the seat that did not audit', () => {
    const stages = reviewStages()
    const audit = stages.find((s) => s.id === 'audit')
    const cross = stages.find((s) => s.id === 'crossAudit')
    expect(audit?.seat).not.toBe(cross?.seat)
  })

  it('ignores maxTurns, because the review protocol is fixed', () => {
    expect(stagesFor('review', 20)).toHaveLength(4)
  })
})

describe('debatePrompt', () => {
  const base = {
    matter: 'adopt a queue?',
    repoPath: null,
    opponentMessage: null,
    interjections: [] as string[],
  }

  it('does not mention an opponent on the opening turn', () => {
    const prompt = debatePrompt({ ...base, stage: { id: 'open', label: 'Position', seat: 0 } })
    expect(prompt).toContain('adopt a queue?')
    expect(prompt).not.toContain('latest message')
  })

  it('relays only the opponent latest message, never a transcript', () => {
    const prompt = debatePrompt({
      ...base,
      stage: { id: 'attack.1', label: 'Challenge', seat: 1 },
      opponentMessage: 'my single previous message',
    })
    expect(prompt).toContain('my single previous message')
  })

  it('marks director interjections as outranking the other advisor', () => {
    const prompt = debatePrompt({
      ...base,
      stage: { id: 'refine.1', label: 'Defence', seat: 0 },
      opponentMessage: 'x',
      interjections: ['assume 10x load'],
    })
    expect(prompt).toContain('assume 10x load')
    expect(prompt).toMatch(/take precedence/i)
  })

  it('omits the direction block entirely when there is nothing to relay', () => {
    const prompt = debatePrompt({ ...base, stage: { id: 'open', label: 'Position', seat: 0 } })
    expect(prompt).not.toMatch(/HUMAN DIRECTOR/)
  })
})

describe('a correction reaching the agent that acts on it', () => {
  /**
   * The failure this guards against, observed in a real run: the auditor
   * demanded a strict engine-version check, the planner correctly rejected it
   * as a change that would break the suite on a routine patch release, recorded
   * that in a disposition — and the executor, which sees only the milestone,
   * built the strict check anyway. The reasoning existed and never arrived.
   */
  const decisions = [
    'codex audited the plan and judged it needs-changes.',
    '• PARTLY-ACCEPTED — The harness should fail when the engine is not exactly 4.7.1.:',
    'Guard added on major.minor. Exact-patch pinning would break the suite on a 4.7.2 release.',
  ].join('\n')

  it('carries the settled decisions to the executor', () => {
    const prompt = executePrompt('Scaffold', 'an engine-version guard', [], '/repo', decisions)
    expect(prompt).toContain('Exact-patch pinning would break the suite')
    expect(prompt).toMatch(/ALREADY SETTLED/)
  })

  it('tells the executor to build the decision, not the original finding', () => {
    const prompt = executePrompt('Scaffold', 'an engine-version guard', [], '/repo', decisions)
    expect(prompt).toMatch(/rather than what the finding originally asked for/i)
  })

  it('lets a disagreement be voiced rather than silently acted on', () => {
    // A executor that silently "corrects" a decision it dislikes is the same
    // failure in the opposite direction.
    const prompt = executePrompt('Scaffold', 'intent', [], '/repo', decisions)
    expect(prompt).toMatch(/implement it and say so/i)
  })

  it('omits the section entirely when there is nothing settled', () => {
    const prompt = executePrompt('Scaffold', 'intent', [], '/repo', '')
    expect(prompt).not.toContain('ALREADY SETTLED')
  })

  it('treats whitespace-only decisions as nothing', () => {
    const prompt = executePrompt('Scaffold', 'intent', [], '/repo', '   \n  ')
    expect(prompt).not.toContain('ALREADY SETTLED')
  })

  it('carries a realistic correction record whole', () => {
    // Measured from a real 11-milestone plan: ~8k characters. Truncating that
    // drops rulings by position rather than by relevance, which is the bug this
    // whole change exists to fix.
    const realistic = 'ruling. '.repeat(1100)
    const prompt = executePrompt('Scaffold', 'intent', [], '/repo', realistic)
    expect(prompt).toContain(realistic.trim())
  })

  it('still bounds a runaway record, keeping the tail', () => {
    const absurd = 'x'.repeat(40_000) + 'FINAL-RULING'
    const prompt = executePrompt('Scaffold', 'intent', [], '/repo', absurd)
    expect(prompt).toContain('FINAL-RULING')
    expect(prompt.length).toBeLessThan(26_000)
  })

  it('still works with the argument omitted, as older callers do', () => {
    const prompt = executePrompt('Scaffold', 'intent', ['a.ts'], '/repo')
    expect(prompt).toContain('MILESTONE: Scaffold')
    expect(prompt).not.toContain('ALREADY SETTLED')
  })

  it('tells the planner its dispositions are not instructions', () => {
    // The root cause: a decision recorded only in a disposition is invisible to
    // the builder, so the contract has to say where a decision must land.
    expect(CORRECTION_CONTRACT).toMatch(/sees that milestone and nothing else/i)
    expect(CORRECTION_CONTRACT).toMatch(/must appear in the milestone's own "intent"/i)
  })
})

describe('telling the executor how its work gets checked', () => {
  /**
   * Observed failure this closes: an executor that was never told a verification
   * command existed, tried to run one anyway, and hit a sandbox that blocks the
   * engine from writing outside the workspace. Godot aborted a second into every
   * attempt while the identical command, run by the workbench, passed eleven
   * test files. Left to interpret a segfault, an executor can reasonably conclude
   * the repository is broken and start "fixing" it.
   */
  it('names the command that will judge the work', () => {
    const prompt = executePrompt('Cap the wrapper', 'add a timeout', [], '/repo', '', 'tests/run.sh')
    expect(prompt).toContain('tests/run.sh')
    expect(prompt).toMatch(/the workbench runs this itself, outside your sandbox/i)
  })

  it('tells the executor a toolchain failure is not its bug to fix', () => {
    const prompt = executePrompt('m', 'i', [], '/repo', '', 'tests/run.sh')
    expect(prompt).toMatch(/that is your sandbox and not a defect/i)
    // And that the authoritative run is the workbench's, so a local crash is
    // not evidence the milestone failed.
    expect(prompt).toMatch(/the workbench's own run is the one that counts/i)
  })

  it('promises the output comes back, which is what makes leaving it safe', () => {
    const prompt = executePrompt('m', 'i', [], '/repo', '', 'tests/run.sh')
    expect(prompt).toMatch(/comes back to you if it fails/i)
  })

  it('says nothing when the milestone has no verification command', () => {
    // Silence is correct here: inventing a command, or implying one exists, is
    // worse than admitting the milestone is judged on the diff alone.
    const prompt = executePrompt('m', 'i', [], '/repo', '', '')
    expect(prompt).not.toMatch(/HOW YOUR WORK WILL BE CHECKED/)
  })

  it('still works for callers that pass neither decisions nor a command', () => {
    const prompt = executePrompt('m', 'i', ['a.gd'], '/repo')
    expect(prompt).toContain('MILESTONE: m')
    expect(prompt).not.toContain('ALREADY SETTLED')
    expect(prompt).not.toMatch(/HOW YOUR WORK WILL BE CHECKED/)
  })
})

describe('the neutralised-verification rule', () => {
  /**
   * Named separately from the general unverified-claim rule after appearing five
   * times in six milestones and being misfiled as advisory even once the
   * blocking/notes split existed. The last instance was demonstrated: with one
   * environment variable set, the verification command exited 0 with no output
   * and every test deliberately broken. The reviewer identified it, cited the
   * project rule forbidding it, and filed it under notes.
   */
  it('is stated as its own blocking case, not left to the general principle', () => {
    expect(REVIEW_CONTRACT).toMatch(/verification can be made to pass without running/i)
  })

  it('names the concrete shapes rather than describing the idea', () => {
    for (const shape of [
      /empty or unreadable test directory/i,
      /cannot load and exits 0/i,
      /environment variable or argument that short-circuits/i,
    ]) {
      expect(REVIEW_CONTRACT).toMatch(shape)
    }
  })

  /**
   * Milestone 1 of the ledger plan passed with six "notes", three of which named
   * incorrect behaviour: a coverage predicate that admitted the case its own
   * description excluded, a hand-rolled SHA-256 whose only known-answer vector was
   * shorter than every production input, and a nullable default that silently
   * widened a destructive scope. Deriving `passed` from `blocking` closed the
   * "tick it anyway" hole; this closes the one next to it.
   */
  it('refuses the downgrade route into notes', () => {
    expect(REVIEW_CONTRACT).toMatch(/however narrow the window/i)
    expect(REVIEW_CONTRACT).toMatch(/rarely you judge it to fire is not a reason to downgrade/i)
    // The self-check at the point of writing, not just a rule earlier in the prompt.
    expect(REVIEW_CONTRACT).toMatch(/read it back to yourself/i)
    expect(REVIEW_CONTRACT).toMatch(/same failure as ticking "passed" beside it/i)
  })

  it('names the words a reviewer uses when it is describing a defect', () => {
    for (const tell of [/silently/i, /never fires/i, /is skipped/i, /clears everything/i]) {
      expect(REVIEW_CONTRACT).toMatch(tell)
    }
  })

  it('blocks an untested primitive rather than accepting that it was read carefully', () => {
    expect(REVIEW_CONTRACT).toMatch(/whose real path is untested/i)
    expect(REVIEW_CONTRACT).toMatch(/single-block vector/i)
    // The specific excuse that let the hash through: "I traced it and it is correct."
    expect(REVIEW_CONTRACT).toMatch(/Reading it and finding it correct is not a substitute/i)
  })

  it('forecloses the two excuses that produced the misfiling', () => {
    // "unlikely to happen" and "nothing is broken today" are exactly how a
    // reviewer talks itself into notes.
    expect(REVIEW_CONTRACT).toMatch(/however unlikely you judge the trigger/i)
    expect(REVIEW_CONTRACT).toMatch(/whether or not anything is broken today/i)
  })

  it('tells the reviewer where its own sentence belongs', () => {
    // The tell is linguistic: a reviewer writing "could report success without
    // testing anything" has already found a blocking problem.
    expect(REVIEW_CONTRACT).toMatch(/that sentence belongs in "blocking", not "notes"/i)
  })

  it('still tells the reviewer not to block on taste', () => {
    // Guard against the sharpening turning into a licence to block on anything.
    expect(REVIEW_CONTRACT).toMatch(/Do not block on taste/i)
  })
})

describe('remediationPrompt and mutation checks', () => {
  const base = {
    round: 1,
    maxRounds: 2,
    concerns: [] as string[],
    reviewerNote: '',
    testSummary: 'tests passed',
    reviewerVendor: 'claude',
  }

  it('carries the surviving break to the executor, with what to do about it', () => {
    const prompt = remediationPrompt({
      ...base,
      mutationSummary: '  SURVIVED — game.gd: the win check. The suite still passed.',
    })
    expect(prompt).toMatch(/MUTATION CHECKS/)
    expect(prompt).toMatch(/SURVIVED — game\.gd/)
    // The instruction matters as much as the fact: strengthen the tests, do not
    // implement the broken behaviour the mutation simulated.
    expect(prompt).toMatch(/strengthen the tests/)
    expect(prompt).toMatch(/not to change the behaviour the break simulates/)
  })

  it('omits the block entirely when there were no mutation checks', () => {
    expect(remediationPrompt(base)).not.toMatch(/MUTATION CHECKS/)
  })

  it('hands the adopt reviewer the mutation outcomes when the checks ran', () => {
    // Adoption runs the declared breaks too, and the adopt reviewer is told to
    // press on whether the tests are real — a tried break answers that by
    // trial, so it must reach the prompt just as it does in a supervised
    // review.
    const prompt = adoptReviewPrompt(
      'title',
      'intent',
      'the diff',
      'tests passed',
      [],
      [],
      '  CAUGHT — src/a.ts: the cap must stay on. The suite failed as it should.',
    )
    expect(prompt).toMatch(/MUTATION CHECKS/)
    expect(prompt).toMatch(/CAUGHT — src\/a\.ts/)
    expect(adoptReviewPrompt('title', 'intent', 'the diff', 'tests passed')).not.toMatch(
      /MUTATION CHECKS/,
    )
  })
})
