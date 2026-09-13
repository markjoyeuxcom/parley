# Worktrees roadmap

Recorded 13 September 2026 after the v0.1.49 acceptance pass and a tester's
design assessment of the worktree feature. This is the agreed shape; the
engineering guide (`AGENTS.md`, "Managed Git worktrees") remains the rule
book for what ships.

## Principle

Worktrees are Parley's code-level ledger. The relay records who said what to
whom; a worktree records what code a piece of delegated work produced, where
it sits, and what happened to it. Parley reads and explains Git state. It
runs Git itself only to create and remove a tree after a preview the person
approved. Every consequential Git action (merge, push, rebase, branch
deletion) is either the person's own terminal work or a reviewed command run
with the person's per-run approval or the automatic-approval switch they keep
in Settings. Parley never infers intent from terminal text and never adds a
workflow state machine; a tree's state is derived from facts each time it is
read.

## Now (this branch)

- **The board.** The worktree browser's "Managed by Parley" list shows one
  row per tree: branch, owner (team with its state, requesting pane with
  running / stopped / closed, you, or person-owned), recorded base, HEAD,
  changed paths, commits ahead of and behind the primary checkout, and a
  state derived from those facts: In use, Idle, Integrated, Missing, Unknown
  or Not read yet. Presentation over facts Parley already records, plus two
  bounded Git reads per tree (`rev-list --left-right --count` and
  `merge-base --is-ancestor`) in the existing background facts pass.
- **Integrate as a reviewed run.** A row's **Integrate…** proposes the exact
  `git merge --no-ff --no-edit --end-of-options <branch>` in the repository's
  primary checkout as a person-proposed reviewed command run. It opens the
  same editable preview as an agent's `request-run`, always waits for the
  person's approval (the automatic switch and session grants do not apply to
  a run the person proposed), runs in a new Shell pane with its exit status
  and output captured, and is recorded in the handoff journal as a command
  run whose requester is the person. After the run, the tree reads as
  Integrated once its HEAD is contained in the primary's HEAD, and the
  existing removal checks pass on their own.

## Later, only if the beta week's reports ask for it

- **Delegate with a worktree.** `parley delegate <target> --worktree <branch>`
  creates a previewed tree for one task; the target pane keeps its folder at
  the repository root, which every vendor's permission root already covers,
  and the return snapshot shows whether the primary checkout was touched.
  Build this only after a report of two agents editing the same files.
- **Same-file collision report.** Intersect each tree's changed paths against
  its base and mark rows that overlap. Report only, never resolution.
- **Context Pack provenance from a worktree.** A Git Diff part captured
  inside a tree names the tree, branch and base and says whether the diff
  changed since capture, computed at approval time from facts.
- **Agent finished versus worktree resolved.** If wanted, derive it: a
  returned delegation whose tree still has commits ahead of the primary is
  unresolved. No stored state.

## Decided against (13 September 2026)

- A "Move writers into separate worktrees" action and any one-tree-per-pane
  default. One tree per feature or team stays the rule, and Parley never
  creates a tree silently.
- Writers isolated in trees while reviewers share the checkout, which needs
  a team grant bound to two folders. Multi-folder grants stay deferred.
- A merge, rebase or push performed by Parley itself. Integrate above is a
  reviewed command run in a Shell pane the person approved, not a Parley Git
  action.

## What already existed and was mistaken for missing

Close pane and remove worktree were always separate steps; removal already
refuses modified or untracked files, commits ahead of the upstream, and a
branch with no upstream that is not contained in the primary; changed paths,
ahead counts and the merge prediction were already in Finish & Cleanup. The
board exists so those facts are visible without opening that tab.
