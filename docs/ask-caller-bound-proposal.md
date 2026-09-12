# Ask: the blocked pane, and a correlation defect found underneath it

**Status:** decision document plus one implementable spec.

Mark asked whether `parley ask` could stop blocking the sending pane. Two
rounds of independent review by Codex and Agy followed. The blocking question
has no cheap answer worth taking. The investigation did surface a correctness
defect that is worth fixing on its own, and that fix needs no protocol bump.

## Verified behaviour

Read from source at `ee7b189`. Every line reference re-checked after review.

- `consultationTimeout` defaults to `30 * 60` (`Relay.swift:528`); nothing
  overrides it. It governs three different waits: the Ask block, the
  `ask-many` children, and the human context-review approval (`:985`).
- The Ask deadline is `createdAt + consultationTimeout` where `createdAt` is
  the **submission** transition (`:3847-3849`). It measures time since the
  question was sent, not the target's own workload.
- On expiry `finishAskLocked` **removes** the consultation record (`:3951`).
- `waitForTrackedWork` is `while true` with a liveness poll and **no overall
  deadline** (`:2404-2417`).
- `parley cancel <id|current>` finishes the consultation as `.cancelled`
  (`:3543`) and frees the target. A *blocked* caller cannot run it: its tool
  call is inside the blocking request.
- Target refusal busy-ness is `targetHasTrackedWorkLocked` (`:2100`, `:3713`) —
  tracked consultations and delegations only. An agent deep in its own
  unrelated work is not busy by this definition.
- `parley answer current` resolves to the sender pane's single consultation
  with `completion == nil` (`:3099-3110`).
- `AgentProtocol.text` already instructs: "When a received consultation
  includes `parley answer <id>`, return the answer through that exact command"
  (`AgentProtocol.swift:66`). Protocol version is 32.
- `consultationPrompt` nevertheless emits `parley answer current` and tells the
  target "do not copy or invent an id" (`Relay.swift:3961-3973`).

## Part 1 — the blocked pane: no change recommended

The original proposal here split the timeout into a short caller bound and a
long consultation lifetime. **It does not survive review.** `parley wait` has
no deadline, so an agent obeying a "timed out, recover with `parley wait <id>`"
response re-blocks for the remainder. It also required deadline ownership that
does not exist outside `waitForAskResponse`, and would have falsely failed
live context Asks through `finishContextReview` (`:1028`, `:1298`).

The fallback — simply shortening the Ask lifetime to about five minutes — is
also **not recommended**, for a reason that only emerged in the second review.

Because the deadline runs from submission, a long-running target is not the
failure mode it appears to be. A target 20 minutes into a 45-minute task, asked
at minute 20, still has until minute 50 under today's budget; it can finish at
45 and answer successfully. A five-minute lifetime expires at minute 25 and
rejects that same answer. Shortening trades less caller waiting for more
rejected answers, and it degrades exactly the scenario that prompted the
question.

An earlier draft of this document claimed a shorter lifetime "does not fail
answers that would have arrived". That was false and contradicted its own cost
paragraph.

Reviewers split on this and the disagreement is recorded rather than resolved:
Codex recommends keeping the current timeout and using Delegate when the
recipient may be unavailable, noting that response time and service time are
different things. Agy recommends five minutes, on the basis that a target busy
for longer is not suitable for a synchronous Ask.

What remains true regardless: **a blocked caller has no self-service exit.**
Only the target answering, the deadline, or the person's **Cancel Wait…** ends
it. That is a real limitation, and it is the honest answer to Mark's question:
Ask cannot stop blocking without either duplicating Delegate or rebuilding
deadline ownership as a project.

## Part 2 — the correlation defect: spec

### The defect

`parley answer current` resolves to whichever consultation the target pane
currently holds unanswered. Consider:

1. Ask #1 is delivered to a target and expires. Its record is removed.
2. Ask #2 is delivered to the same target.
3. The target finishes #1's work and runs `parley answer current`.
4. It resolves to **#2**: `matches.count == 1`, so the answer is accepted.

The requester of #2 receives an answer to a question it never asked, and Parley
reports success. No error surfaces anywhere. This is a silent wrong result, and
it is worse than any ergonomic problem in Part 1.

Shortening the Ask lifetime would make it **more** frequent, by creating more
expired-then-replaced windows. That is a further argument against Part 1's
fallback.

### Root cause

The generated prompt teaches the hazard. `consultationPrompt` emits
`parley answer current` and states "Parley identifies the waiting question from
this pane's credential, so do not copy or invent an id", which directly
contradicts `AgentProtocol.text:66`.

### Change

Make delivery match the contract that already exists.

1. `consultationPrompt` emits the exact id:
   `parley answer <consultation-id> "your answer"`, and the same id for the
   multiline form.
2. Remove "do not copy or invent an id". Replace with wording stating that the
   id names this exact question and must be used verbatim.
3. Keep `parley answer current` working. It stays in the protocol and remains
   correct when a pane holds exactly one waiting consultation.
4. When an **explicit id** names a consultation that is gone, report the
   retained terminal outcome instead of a bare `404 unknown consultation`:
   which state it reached and when, that the answer was not accepted or
   delivered, and that retrying will not reopen it. Respect the existing
   generation and retention rules; do not expose another pane's records.
5. Leave the `current`-with-no-consultation path generic (`:3099-3110`).
   Parley genuinely cannot know which earlier question the text was meant for,
   and must not guess by picking the most recent expired record.

### Why no protocol bump

`AgentProtocol.text` is unchanged: it already directs agents to use the exact
`parley answer <id>` a consultation supplies. Only generated delivery content
changes, which invariant 8 explicitly permits. Version stays 32 and no pane
shows **RESTART FOR PROTOCOL**.

The prompt is generated per consultation at delivery time, so panes already
running pick up the new wording for their next question with no restart.

### Checks, failing first

- The delivered prompt contains the exact consultation id and does not contain
  `current`.
- **The hazard itself:** #1 expires, #2 is delivered to the same target, and an
  answer naming #1's id is refused rather than applied to #2. This must be
  watched failing: today a `current` answer silently lands on #2.
- An explicit-id answer to an expired consultation is refused with its recorded
  terminal state and time, not a bare 404.
- `current` still answers correctly when exactly one consultation is waiting.
- `current` with none waiting keeps its existing generic refusal.
- Each `ask-many` child prompt carries its own distinct id.
- A target pane from an earlier generation still cannot answer.

### Risks

- An agent may use `current` from habit or from an older prompt already in its
  scrollback. The change removes the instruction that teaches it, but cannot
  prevent it. The hazard is narrowed, not eliminated.
- Wording alone never proves model uptake; this is configuration evidence, the
  same class as any other instruction.

## Rejected

- **`--detach` on Ask.** Duplicates Delegate. Codex notes the rejection should
  be "unnecessary surface for this fix" rather than "asynchronous questions are
  incoherent"; recorded as such.
- **Splitting caller wait from lifetime.** Requires independent deadline
  ownership, a bounded `parley wait`, pending-versus-terminal discipline,
  context-Ask and native Compare handling, and `ask-many` bundle semantics. A
  project, not a tweak. Codex supports the direction under those conditions;
  Agy considers it the wrong abstraction.
- **Shortening the Ask lifetime.** See Part 1.
- **Warning an asker from hook signals.** Both reviewers note a blocked caller
  cannot read it. Agy adds vendor asymmetry (Agy has no session hook) and
  `turn-ended` never firing after a crash.

## Corrections to earlier drafts of this document

Recorded so the errors are not repeated:

- It stated a late answer receives `409`. It receives `404`, because
  `finishAskLocked` removes the record.
- It claimed the target cannot be re-asked for 30 minutes. `parley cancel`
  frees it.
- It claimed a shorter lifetime fails no answer that would have arrived. False.
- It claimed both reviewers killed the split. Only Agy did; Codex supported the
  direction with conditions.
- It proposed fixing the target prompt's "the requester is blocked" wording.
  That wording is correct unless the split is adopted.
