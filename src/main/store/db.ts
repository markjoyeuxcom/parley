import { DatabaseSync } from 'node:sqlite'
import { mkdirSync } from 'node:fs'
import { dirname } from 'node:path'

/**
 * Local persistence.
 *
 * `node:sqlite` ships inside Node 24, which Electron 43 embeds, so this adds no
 * native module to compile or notarise — node-pty is the only one we cannot
 * avoid. The surface used here is deliberately small (`exec`, `prepare`, `run`,
 * `get`, `all`), so swapping to better-sqlite3 later means rewriting this file
 * and nothing else.
 *
 * Nothing in this database ever leaves the machine. There is no sync, no
 * telemetry, and no remote backup.
 */

export type Row = Record<string, unknown>

export interface Db {
  exec(sql: string): void
  run(sql: string, ...params: unknown[]): { changes: number }
  get<T = Row>(sql: string, ...params: unknown[]): T | undefined
  all<T = Row>(sql: string, ...params: unknown[]): T[]
  transaction<T>(fn: () => T): T
  close(): void
}

export const SCHEMA_VERSION = 32

const SCHEMA = `
CREATE TABLE IF NOT EXISTS meta (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS sessions (
  id         TEXT PRIMARY KEY,
  kind       TEXT NOT NULL,
  status     TEXT NOT NULL,
  matter     TEXT NOT NULL,
  project    TEXT NOT NULL DEFAULT '',
  repo_path  TEXT,
  -- The participants in seat order, as a JSON array. Nullable for parity with
  -- databases migrated up from the two-sided era, not because a session can
  -- lack them; every writer sets the column, and v11 backfilled every old row.
  participants TEXT,
  max_turns  INTEGER NOT NULL,
  usage      TEXT NOT NULL,
  mock       INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL,
  ended_at   INTEGER,
  error      TEXT,
  -- When the user put this session out of the way. Hidden from the list, not
  -- deleted: the transcript, verdict and any plan remain the record of why work
  -- happened, and a cluttered sidebar is not a reason to destroy that.
  archived_at INTEGER
);
CREATE INDEX IF NOT EXISTS idx_sessions_created ON sessions(created_at DESC);

CREATE TABLE IF NOT EXISTS turns (
  id         TEXT PRIMARY KEY,
  session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  idx        INTEGER NOT NULL,
  -- Which participant spoke, as an index into the session's seating order.
  -- Nullable for parity with migrated databases; every writer sets it.
  seat       INTEGER,
  vendor     TEXT NOT NULL,
  model      TEXT NOT NULL DEFAULT '',
  stage      TEXT NOT NULL,
  text       TEXT NOT NULL DEFAULT '',
  usage      TEXT NOT NULL,
  started_at INTEGER NOT NULL,
  ended_at   INTEGER,
  error      TEXT
);
CREATE INDEX IF NOT EXISTS idx_turns_session ON turns(session_id, idx);

-- Vendor session ids, kept out of the turn rows because they are per
-- (session, side) rather than per turn. Resuming by these ids is what keeps
-- token cost linear in turn count.
CREATE TABLE IF NOT EXISTS agent_threads (
  session_id TEXT NOT NULL,
  seat       INTEGER NOT NULL,
  resume_id  TEXT NOT NULL,
  PRIMARY KEY (session_id, seat)
);

-- Delivery is tracked per seat, not once per row. An 'all' interjection has to
-- reach each seat exactly once, and seats take their turns at different times,
-- so a single delivered_at would let whichever seat read it first swallow the
-- message. Old rows may still spell target as 'both'/'a'/'b'; reads map them.
CREATE TABLE IF NOT EXISTS interjections (
  id             TEXT PRIMARY KEY,
  session_id     TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  target         TEXT NOT NULL,
  text           TEXT NOT NULL,
  at_turn_index  INTEGER NOT NULL,
  created_at     INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_interject_session ON interjections(session_id, created_at);

CREATE TABLE IF NOT EXISTS interjection_deliveries (
  interjection_id TEXT NOT NULL REFERENCES interjections(id) ON DELETE CASCADE,
  seat            INTEGER NOT NULL,
  delivered_at    INTEGER NOT NULL,
  PRIMARY KEY (interjection_id, seat)
);

CREATE TABLE IF NOT EXISTS verdicts (
  session_id TEXT PRIMARY KEY REFERENCES sessions(id) ON DELETE CASCADE,
  decision   TEXT NOT NULL,
  rationale  TEXT NOT NULL,
  scores     TEXT NOT NULL,
  confidence REAL NOT NULL,
  dissent    TEXT NOT NULL DEFAULT '',
  report     TEXT NOT NULL,
  created_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS findings (
  id         TEXT PRIMARY KEY,
  session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  priority   TEXT NOT NULL,
  status     TEXT NOT NULL,
  title      TEXT NOT NULL,
  detail     TEXT NOT NULL DEFAULT '',
  evidence   TEXT NOT NULL DEFAULT '[]',
  raised_by  TEXT NOT NULL,
  created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_findings_session ON findings(session_id, priority);

CREATE TABLE IF NOT EXISTS ledger_findings (
  id              TEXT PRIMARY KEY,
  session_id      TEXT NOT NULL,
  text            TEXT NOT NULL,
  normalized_text TEXT NOT NULL,
  created_at      INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_ledger_findings_session
  ON ledger_findings(session_id, created_at);

CREATE TABLE IF NOT EXISTS ledger_sightings (
  id           TEXT PRIMARY KEY,
  finding_id   TEXT NOT NULL REFERENCES ledger_findings(id) ON DELETE CASCADE,
  plan_id      TEXT NOT NULL,
  milestone_id TEXT,
  round        INTEGER,
  kind         TEXT NOT NULL,
  source       TEXT NOT NULL,
  seq          INTEGER NOT NULL,
  -- Where the reviewer said it is. On the SIGHTING rather than the finding:
  -- findings are deduped by normalised text, and the same claim seen in two
  -- places points at two different lines.
  evidence     TEXT NOT NULL DEFAULT '[]',
  created_at   INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_ledger_sightings_finding
  ON ledger_sightings(finding_id, seq);

CREATE TABLE IF NOT EXISTS ledger_dispositions (
  id            TEXT PRIMARY KEY,
  finding_id    TEXT NOT NULL REFERENCES ledger_findings(id) ON DELETE CASCADE,
  occurrence_id TEXT REFERENCES ledger_sightings(id) ON DELETE CASCADE,
  state         TEXT NOT NULL,
  note          TEXT NOT NULL DEFAULT '',
  source        TEXT NOT NULL,
  seq           INTEGER NOT NULL,
  created_at    INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_ledger_dispositions_finding
  ON ledger_dispositions(finding_id, seq);
CREATE INDEX IF NOT EXISTS idx_ledger_dispositions_occurrence
  ON ledger_dispositions(occurrence_id, seq);

CREATE TABLE IF NOT EXISTS plans (
  id         TEXT PRIMARY KEY,
  session_id TEXT NOT NULL,
  kind       TEXT NOT NULL,
  title      TEXT NOT NULL,
  repo_path  TEXT NOT NULL,
  planner    TEXT NOT NULL,
  executor   TEXT NOT NULL,
  reviewer   TEXT NOT NULL,
  status     TEXT NOT NULL,
  usage      TEXT NOT NULL,
  mock       INTEGER NOT NULL DEFAULT 0,
  question   TEXT NOT NULL DEFAULT '',
  correction_note TEXT NOT NULL DEFAULT '',
  -- The planner's verdict on each audit finding, kept structured so the surface
  -- can table it rather than printing eight thousand characters of prose.
  correction_dispositions TEXT NOT NULL DEFAULT '[]',
  -- Everything needed to resume a stage the user was asked a question during.
  -- One JSON column rather than a column per stage input, because what a
  -- resumed stage needs differs by stage and would otherwise keep growing.
  pending    TEXT,
  -- Where milestones execute: 'checkout' (the live tree, the original
  -- behavior) or 'worktree' (an isolated per-plan branch, landed by a human).
  isolation  TEXT NOT NULL DEFAULT 'checkout',
  setup_command TEXT NOT NULL DEFAULT '',
  -- Snapshot of the repository's dev-container choice at creation time, so
  -- what the approval said is what the execution does.
  container  INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_plans_created ON plans(created_at DESC);

CREATE TABLE IF NOT EXISTS milestones (
  id             TEXT PRIMARY KEY,
  plan_id        TEXT NOT NULL REFERENCES plans(id) ON DELETE CASCADE,
  idx            INTEGER NOT NULL,
  title          TEXT NOT NULL,
  intent         TEXT NOT NULL DEFAULT '',
  expected_paths TEXT NOT NULL DEFAULT '[]',
  status         TEXT NOT NULL,
  audit_note     TEXT NOT NULL DEFAULT '',
  test_command   TEXT NOT NULL DEFAULT '',
  test_result    TEXT,
  review_note    TEXT NOT NULL DEFAULT '',
  review_passed  INTEGER,
  adopted        INTEGER NOT NULL DEFAULT 0,
  approval_id    TEXT,
  created_at     INTEGER NOT NULL,
  completed_at   INTEGER,
  mutations        TEXT NOT NULL DEFAULT '[]',
  mutation_results TEXT NOT NULL DEFAULT '[]',
  review_blocking  TEXT NOT NULL DEFAULT '[]',
  review_notes     TEXT NOT NULL DEFAULT '[]',
  -- Everything a resumed run needs, as one JSON blob (the plans.pending
  -- argument: what a resumption needs keeps growing, and a column per field
  -- would too). Written during a run, cleared on completion and at retry or
  -- adoption entry, preserved on failure — its presence is what "resumable"
  -- means. The domain carries only a summary; the baseline inside can be
  -- large and never crosses IPC.
  run_state        TEXT
);
CREATE INDEX IF NOT EXISTS idx_milestones_plan ON milestones(plan_id, idx);

-- Single-use human authorisations. The consumed_at column is the whole point:
-- the orchestrator spends an approval with a conditional UPDATE, so a second
-- attempt to spend the same approval affects zero rows and is refused.
CREATE TABLE IF NOT EXISTS approvals (
  id          TEXT PRIMARY KEY,
  scope       TEXT NOT NULL,
  subject_id  TEXT NOT NULL,
  summary     TEXT NOT NULL,
  granted_at  INTEGER NOT NULL,
  consumed_at INTEGER
);
CREATE INDEX IF NOT EXISTS idx_approvals_subject ON approvals(subject_id, scope, consumed_at);

CREATE TABLE IF NOT EXISTS loops (
  id              TEXT PRIMARY KEY,
  goal            TEXT NOT NULL,
  repo_path       TEXT NOT NULL,
  worker          TEXT NOT NULL,
  verifier        TEXT NOT NULL,
  exit_condition  TEXT NOT NULL,
  caps            TEXT NOT NULL,
  capability      TEXT NOT NULL,
  -- Snapshot of the repository's dev-container choice at creation time.
  container       INTEGER NOT NULL DEFAULT 0,
  approval_id     TEXT,
  status          TEXT NOT NULL,
  usage           TEXT NOT NULL,
  iteration_count INTEGER NOT NULL DEFAULT 0,
  mock            INTEGER NOT NULL DEFAULT 0,
  started_at      INTEGER NOT NULL,
  ended_at        INTEGER,
  stop_reason     TEXT NOT NULL DEFAULT '',
  -- When the loop last showed real activity, for stall detection. Written on
  -- activity only (throttled), never on a watchdog tick.
  last_activity_at INTEGER
);
CREATE INDEX IF NOT EXISTS idx_loops_started ON loops(started_at DESC);

CREATE TABLE IF NOT EXISTS loop_iterations (
  id          TEXT PRIMARY KEY,
  loop_id     TEXT NOT NULL REFERENCES loops(id) ON DELETE CASCADE,
  idx         INTEGER NOT NULL,
  vendor      TEXT NOT NULL,
  summary     TEXT NOT NULL DEFAULT '',
  usage       TEXT NOT NULL,
  exit_met    INTEGER NOT NULL DEFAULT 0,
  exit_detail TEXT NOT NULL DEFAULT '',
  started_at  INTEGER NOT NULL,
  ended_at    INTEGER,
  error       TEXT
);
CREATE INDEX IF NOT EXISTS idx_iterations_loop ON loop_iterations(loop_id, idx);

-- Saved grid arrangements. The tree is stored without ids: it describes what
-- each pane is, so restoring mints fresh slots rather than reviving dead ones.
CREATE TABLE IF NOT EXISTS grid_layouts (
  id             TEXT PRIMARY KEY,
  name           TEXT NOT NULL,
  default_folder TEXT NOT NULL DEFAULT '',
  tree           TEXT NOT NULL,
  created_at     INTEGER NOT NULL,
  updated_at     INTEGER NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_layouts_name ON grid_layouts(name);

CREATE TABLE IF NOT EXISTS skills (
  id          TEXT PRIMARY KEY,
  name        TEXT NOT NULL,
  description TEXT NOT NULL DEFAULT '',
  prompt      TEXT NOT NULL,
  vendor_hint TEXT,
  built_in    INTEGER NOT NULL DEFAULT 0
);

-- Decision holds are derived, never stored — see shared/holds.ts. These two
-- tables carry the only durable facts about one: that a human acknowledged a
-- notice-class hold, and that it was notified once. Both are keyed by the
-- content-addressed hold identity, which is what lets them survive
-- recomputation and restarts without a holds table to go stale.
CREATE TABLE IF NOT EXISTS hold_acks (
  identity TEXT PRIMARY KEY,
  acked_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS hold_notifications (
  identity    TEXT PRIMARY KEY,
  notified_at INTEGER NOT NULL
);

-- Per-plan isolated checkouts (git worktrees) the audited pipeline executes
-- in. The row is registry, not truth — the directory and the branch are the
-- truth, and startup reconciliation marks rows orphaned when either vanishes.
-- Rows are never deleted by reconciliation: a branch can outlive its
-- directory and still carry unlanded commits.
CREATE TABLE IF NOT EXISTS worktrees (
  plan_id     TEXT PRIMARY KEY,
  origin_path TEXT NOT NULL,
  path        TEXT NOT NULL,
  branch      TEXT NOT NULL,
  base_branch TEXT NOT NULL DEFAULT '',
  base_commit TEXT NOT NULL,
  created_at  INTEGER NOT NULL,
  landed_at   INTEGER,
  last_error  TEXT NOT NULL DEFAULT '',
  orphaned    INTEGER NOT NULL DEFAULT 0
);

-- The per-repository backlog: work items harvested from review findings,
-- accepted risks and stow sweeps, keyed by canonicalised repo path. The id is
-- random and content_hash is only a dedupe key against LIVE items — a done or
-- dropped item must never block a genuine recurrence from filing fresh. The
-- mock flag is invariant-level: a fabricated finding must never read as real
-- work in a real repository's backlog.
CREATE TABLE IF NOT EXISTS backlog_items (
  id                TEXT PRIMARY KEY,
  repo_path         TEXT NOT NULL,
  content_hash      TEXT NOT NULL,
  title             TEXT NOT NULL,
  detail            TEXT NOT NULL DEFAULT '',
  priority          TEXT,
  state             TEXT NOT NULL,
  source            TEXT NOT NULL,
  origin_session_id TEXT,
  -- The acceptance whose note filed this. Deliberately FK-less: provenance
  -- must outlive whatever it points at.
  origin_acceptance_id TEXT,
  plan_id           TEXT,
  evidence          TEXT NOT NULL DEFAULT '[]',
  blocked_by        TEXT NOT NULL DEFAULT '[]',
  mock              INTEGER NOT NULL DEFAULT 0,
  created_at        INTEGER NOT NULL,
  updated_at        INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_backlog_repo_state ON backlog_items(repo_path, state);

-- Append-only trail of what happened to each item and who did it. The state
-- column above is the queryable truth; this is the audit that must always
-- fold to it.
CREATE TABLE IF NOT EXISTS backlog_events (
  id         TEXT PRIMARY KEY,
  item_id    TEXT NOT NULL REFERENCES backlog_items(id) ON DELETE CASCADE,
  kind       TEXT NOT NULL,
  note       TEXT NOT NULL DEFAULT '',
  source     TEXT NOT NULL,
  -- Monotonic, the ledger's lesson: same-millisecond events with random ids
  -- would scramble the trail, and the trail must always fold to the column.
  seq        INTEGER NOT NULL,
  created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_backlog_events_item ON backlog_events(item_id, seq);

-- Curated per-repository learnings. Confirmed entries ride every new plan
-- brief for the repo (capped at render time); retirement is the curation
-- lever. Same mock rule as items.
CREATE TABLE IF NOT EXISTS learnings (
  id                TEXT PRIMARY KEY,
  repo_path         TEXT NOT NULL,
  text              TEXT NOT NULL,
  state             TEXT NOT NULL,
  source            TEXT NOT NULL,
  origin_session_id TEXT,
  mock              INTEGER NOT NULL DEFAULT 0,
  created_at        INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_learnings_repo_state ON learnings(repo_path, state);

-- One read of a repository's backlog by the foreman and the plan it argues
-- for. Attempt rows are filed 'running' before the agent turn dispatches, so
-- an interrupted run is a recorded fact; superseded rows are the history of
-- every read, not just the surviving one. No CHECK constraints on state —
-- validation is Zod-side, like the backlog tables.
CREATE TABLE IF NOT EXISTS foreman_proposals (
  id                TEXT PRIMARY KEY,
  repo_path         TEXT NOT NULL,
  state             TEXT NOT NULL,
  title             TEXT NOT NULL DEFAULT '',
  rationale         TEXT NOT NULL DEFAULT '',
  item_ids          TEXT NOT NULL DEFAULT '[]',
  deferred          TEXT NOT NULL DEFAULT '[]',
  open_snapshot     TEXT NOT NULL DEFAULT '[]',
  isolation         TEXT NOT NULL DEFAULT 'worktree',
  note              TEXT NOT NULL DEFAULT '',
  anchor_session_id TEXT,
  plan_id           TEXT,
  vendor            TEXT NOT NULL,
  usage             TEXT NOT NULL,
  mock              INTEGER NOT NULL DEFAULT 0,
  created_at        INTEGER NOT NULL,
  decided_at        INTEGER,
  decision_note     TEXT NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS idx_foreman_repo_state ON foreman_proposals(repo_path, state);

CREATE TABLE IF NOT EXISTS self_updates (
  id         TEXT PRIMARY KEY,
  plan_id    TEXT NOT NULL,
  state      TEXT NOT NULL,
  detail     TEXT NOT NULL DEFAULT '',
  created_at INTEGER NOT NULL,
  decided_at INTEGER
);
CREATE INDEX IF NOT EXISTS idx_self_updates_state ON self_updates(state);

-- A global append-only watermark for repository-scoped writes. The sequence
-- is the ordering fact: timestamps can tie, and archive visibility depends on
-- distinguishing work that happened before and after the archive record.
CREATE TABLE IF NOT EXISTS repo_activity (
  seq       INTEGER PRIMARY KEY,
  repo_path TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_repo_activity_repo_seq ON repo_activity(repo_path, seq);

-- Archiving is a watermark, not deletion. Later activity makes the repository
-- visible again while retaining this record of the user's earlier decision.
CREATE TABLE IF NOT EXISTS repo_archives (
  repo_path    TEXT PRIMARY KEY,
  archived_seq INTEGER NOT NULL
);

-- The standing per-repository choice to run Parley's own deterministic
-- commands (milestone tests, worktree setup, landing verification, loop
-- exits) inside the repo's dev container. Plans and loops snapshot this at
-- creation, so flipping it never silently changes what an approval meant.
CREATE TABLE IF NOT EXISTS repo_containers (
  repo_path  TEXT PRIMARY KEY,
  enabled    INTEGER NOT NULL DEFAULT 0,
  decided_at INTEGER NOT NULL
);

-- One unattended run's authorisation bounds and outcome. plan_id carries no
-- FK deliberately (the self_updates precedent): session deletion cascades to
-- plans, and an authorisation record must outlive its subject.
CREATE TABLE IF NOT EXISTS envelopes (
  id             TEXT PRIMARY KEY,
  plan_id        TEXT NOT NULL,
  state          TEXT NOT NULL,
  caps           TEXT NOT NULL,
  milestones_run INTEGER NOT NULL DEFAULT 0,
  start_cost_usd REAL NOT NULL DEFAULT 0,
  detail         TEXT NOT NULL DEFAULT '',
  started_at     INTEGER NOT NULL,
  ended_at       INTEGER
);
CREATE INDEX IF NOT EXISTS idx_envelopes_plan ON envelopes(plan_id, started_at DESC);

-- A human's recorded judgement on completed work, and the provenance for any
-- feedback they filed with it. FK-less like every other authorship record.
CREATE TABLE IF NOT EXISTS acceptances (
  id           TEXT PRIMARY KEY,
  milestone_id TEXT NOT NULL,
  plan_id      TEXT NOT NULL,
  repo_path    TEXT NOT NULL,
  state        TEXT NOT NULL,
  note         TEXT NOT NULL DEFAULT '',
  created_at   INTEGER NOT NULL,
  mock         INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_acceptances_milestone
  ON acceptances(milestone_id, created_at DESC);

-- One guided run at building a new app. Links only: the stage is derived
-- from what they point at, never stored.
CREATE TABLE IF NOT EXISTS run_events (
  id              TEXT PRIMARY KEY,
  -- One execution ATTEMPT. A resume is a new run against the same milestone,
  -- so a milestone accumulates several over its life.
  run_id          TEXT NOT NULL,
  milestone_id    TEXT NOT NULL,
  plan_id         TEXT NOT NULL,
  -- Monotonic from 1 within a run. Ordering is the point of a journal, and
  -- occurred_at alone cannot provide it: two events can share a millisecond.
  sequence        INTEGER NOT NULL,
  occurred_at     INTEGER NOT NULL,
  actor_kind      TEXT NOT NULL,
  actor_vendor    TEXT,
  -- The profile the seat was picked from, as of that moment. A column like
  -- its actor siblings: the journal is queried by who, and JSON would hide it.
  actor_profile   TEXT,
  actor_target_id TEXT,
  kind            TEXT NOT NULL,
  payload         TEXT NOT NULL
);

-- No foreign key, following self_updates and envelopes: a run record should
-- outlive the plan a session deletion cascades away. What happened happened,
-- and losing the account of it because its subject was tidied up would defeat
-- the reason for keeping one.
CREATE INDEX IF NOT EXISTS idx_run_events_run ON run_events(run_id, sequence);
CREATE INDEX IF NOT EXISTS idx_run_events_milestone ON run_events(milestone_id, occurred_at);

-- A named way of configuring a seat. Application-global, like remote_targets:
-- it describes how work may be staffed, not that any repository was worked on.
-- Never credentials — the CLIs hold their own authentication, and a profile
-- that carried keys would turn a convenience into a vault.
CREATE TABLE IF NOT EXISTS agent_profiles (
  id         TEXT PRIMARY KEY,
  -- NOCASE: "fast reviewer" and "Fast Reviewer" would be one identity to any
  -- person reading a journal, so they are one identity here too.
  name       TEXT NOT NULL UNIQUE COLLATE NOCASE,
  vendor     TEXT NOT NULL,
  model      TEXT NOT NULL DEFAULT '',
  effort     TEXT NOT NULL DEFAULT 'medium',
  persona    TEXT NOT NULL DEFAULT '',
  created_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS remote_targets (
  id         TEXT PRIMARY KEY,
  label      TEXT NOT NULL,
  -- An ssh destination as ssh itself understands it. An alias from
  -- ~/.ssh/config is the recommended form: it keeps identity files, ports and
  -- jump hosts where they already live rather than duplicating them here.
  host       TEXT NOT NULL,
  -- The command that starts node over there. Usually just 'node'; an absolute
  -- path is the answer for a host where nvm, asdf or mise put it somewhere a
  -- non-interactive ssh session cannot see.
  node_command TEXT NOT NULL DEFAULT 'node',
  runs_root  TEXT NOT NULL DEFAULT '',
  created_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS app_journeys (
  id                TEXT PRIMARY KEY,
  name              TEXT NOT NULL,
  brief             TEXT NOT NULL DEFAULT '',
  session_id        TEXT,
  workspace_id      TEXT,
  plan_id           TEXT,
  harden_session_id TEXT,
  created_at        INTEGER NOT NULL,
  updated_at        INTEGER NOT NULL,
  mock              INTEGER NOT NULL DEFAULT 0
);

-- Projects Parley scaffolded. Also the fourth source of repository
-- membership: a brand-new project has no plan, backlog item or learning, so
-- without this row the Repos surface would not know it exists.
CREATE TABLE IF NOT EXISTS workspaces (
  id          TEXT PRIMARY KEY,
  repo_path   TEXT NOT NULL UNIQUE,
  name        TEXT NOT NULL,
  template_id TEXT NOT NULL,
  state       TEXT NOT NULL,
  detail      TEXT NOT NULL DEFAULT '',
  created_at  INTEGER NOT NULL,
  ready_at    INTEGER,
  mock        INTEGER NOT NULL DEFAULT 0
);

-- A run that left this machine, and whether we ever found out how it went.
--
-- Written after the snapshot is pushed and before anything is spent, because
-- that is the window in which a run becomes recoverable: from then on a dead
-- connection can hide a run that FINISHED, and every value needed to go back
-- and look — which host, which mirror, which commit was submitted — is a
-- local variable that vanishes with the call.
--
-- FK-less, like its neighbours. A row here outlives the plan a session
-- deletion cascades away, because "there is work on a host that nobody
-- collected" stays true regardless of what was tidied up locally.
CREATE TABLE IF NOT EXISTS remote_runs (
  id               TEXT PRIMARY KEY,
  run_id           TEXT NOT NULL,
  milestone_id     TEXT NOT NULL,
  plan_id          TEXT NOT NULL,
  target_id        TEXT NOT NULL,
  -- How git addresses the host's mirror. Kept verbatim rather than rebuilt
  -- from the target, which may have been edited or deleted since.
  mirror_url       TEXT NOT NULL,
  -- The exact tree that was sent. A candidate that does not descend from it
  -- was built from something else and is refused however plausible it looks.
  submitted_commit TEXT NOT NULL,
  -- in-flight: we are watching. unresolved: we stopped watching and do not
  -- know. settled: we know, one way or another.
  state            TEXT NOT NULL,
  detail           TEXT NOT NULL DEFAULT '',
  created_at       INTEGER NOT NULL,
  settled_at       INTEGER
);
CREATE INDEX IF NOT EXISTS idx_remote_runs_state ON remote_runs(state, created_at);

-- One index over everything anybody wrote down.
--
-- The record already answers "what is the state of this plan" perfectly and
-- has never been able to answer "where did anyone say anything about retries"
-- — a question whose answer is spread over a debate, a milestone's intent, a
-- reviewer's finding and a backlog item filed six weeks later, in four tables
-- nothing joins.
--
-- Maintained by TRIGGERS rather than by write-through, which is the whole
-- point: an index kept current by remembering to update it is an index that
-- is silently wrong the first time somebody adds a write site and does not.
-- This codebase already has one guard test whose entire job is catching that
-- class of omission; here the database does it instead.
--
-- porter unicode61 so "retries" finds "retry". The cost is a second copy of
-- the text, which roughly doubles the space the turns take — acceptable for a
-- local record, and stated here rather than discovered.
CREATE VIRTUAL TABLE IF NOT EXISTS search_index USING fts5(
  kind UNINDEXED,
  ref_id UNINDEXED,
  -- Where to go when this is the answer: a session id, or a repository path.
  scope UNINDEXED,
  title,
  body,
  tokenize='porter unicode61'
);

CREATE TRIGGER IF NOT EXISTS search_sessions_ai AFTER INSERT ON sessions BEGIN
  INSERT INTO search_index (kind, ref_id, scope, title, body)
  VALUES ('session', new.id, new.id, new.matter, new.matter || ' ' || new.project);
END;
CREATE TRIGGER IF NOT EXISTS search_sessions_au AFTER UPDATE ON sessions BEGIN
  DELETE FROM search_index WHERE kind = 'session' AND ref_id = old.id;
  INSERT INTO search_index (kind, ref_id, scope, title, body)
  VALUES ('session', new.id, new.id, new.matter, new.matter || ' ' || new.project);
END;
CREATE TRIGGER IF NOT EXISTS search_sessions_ad AFTER DELETE ON sessions BEGIN
  DELETE FROM search_index WHERE kind = 'session' AND ref_id = old.id;
END;

CREATE TRIGGER IF NOT EXISTS search_turns_ai AFTER INSERT ON turns BEGIN
  INSERT INTO search_index (kind, ref_id, scope, title, body)
  VALUES ('turn', new.id, new.session_id, new.vendor || ' · ' || new.stage, new.text);
END;
CREATE TRIGGER IF NOT EXISTS search_turns_au AFTER UPDATE ON turns BEGIN
  DELETE FROM search_index WHERE kind = 'turn' AND ref_id = old.id;
  INSERT INTO search_index (kind, ref_id, scope, title, body)
  VALUES ('turn', new.id, new.session_id, new.vendor || ' · ' || new.stage, new.text);
END;
CREATE TRIGGER IF NOT EXISTS search_turns_ad AFTER DELETE ON turns BEGIN
  DELETE FROM search_index WHERE kind = 'turn' AND ref_id = old.id;
END;

CREATE TRIGGER IF NOT EXISTS search_plans_ai AFTER INSERT ON plans BEGIN
  INSERT INTO search_index (kind, ref_id, scope, title, body)
  VALUES ('plan', new.id, new.repo_path, new.title, new.title || ' ' || new.question);
END;
CREATE TRIGGER IF NOT EXISTS search_plans_au AFTER UPDATE ON plans BEGIN
  DELETE FROM search_index WHERE kind = 'plan' AND ref_id = old.id;
  INSERT INTO search_index (kind, ref_id, scope, title, body)
  VALUES ('plan', new.id, new.repo_path, new.title, new.title || ' ' || new.question);
END;
CREATE TRIGGER IF NOT EXISTS search_plans_ad AFTER DELETE ON plans BEGIN
  DELETE FROM search_index WHERE kind = 'plan' AND ref_id = old.id;
END;

CREATE TRIGGER IF NOT EXISTS search_milestones_ai AFTER INSERT ON milestones BEGIN
  INSERT INTO search_index (kind, ref_id, scope, title, body)
  VALUES ('milestone', new.id, new.plan_id, new.title,
          new.title || ' ' || new.intent || ' ' || new.review_note || ' ' || new.audit_note);
END;
CREATE TRIGGER IF NOT EXISTS search_milestones_au AFTER UPDATE ON milestones BEGIN
  DELETE FROM search_index WHERE kind = 'milestone' AND ref_id = old.id;
  INSERT INTO search_index (kind, ref_id, scope, title, body)
  VALUES ('milestone', new.id, new.plan_id, new.title,
          new.title || ' ' || new.intent || ' ' || new.review_note || ' ' || new.audit_note);
END;
CREATE TRIGGER IF NOT EXISTS search_milestones_ad AFTER DELETE ON milestones BEGIN
  DELETE FROM search_index WHERE kind = 'milestone' AND ref_id = old.id;
END;

CREATE TRIGGER IF NOT EXISTS search_findings_ai AFTER INSERT ON ledger_findings BEGIN
  INSERT INTO search_index (kind, ref_id, scope, title, body)
  VALUES ('finding', new.id, new.session_id, new.text, new.text);
END;
CREATE TRIGGER IF NOT EXISTS search_findings_au AFTER UPDATE ON ledger_findings BEGIN
  DELETE FROM search_index WHERE kind = 'finding' AND ref_id = old.id;
  INSERT INTO search_index (kind, ref_id, scope, title, body)
  VALUES ('finding', new.id, new.session_id, new.text, new.text);
END;
CREATE TRIGGER IF NOT EXISTS search_findings_ad AFTER DELETE ON ledger_findings BEGIN
  DELETE FROM search_index WHERE kind = 'finding' AND ref_id = old.id;
END;

CREATE TRIGGER IF NOT EXISTS search_backlog_ai AFTER INSERT ON backlog_items BEGIN
  INSERT INTO search_index (kind, ref_id, scope, title, body)
  VALUES ('backlog', new.id, new.repo_path, new.title, new.title || ' ' || new.detail);
END;
CREATE TRIGGER IF NOT EXISTS search_backlog_au AFTER UPDATE ON backlog_items BEGIN
  DELETE FROM search_index WHERE kind = 'backlog' AND ref_id = old.id;
  INSERT INTO search_index (kind, ref_id, scope, title, body)
  VALUES ('backlog', new.id, new.repo_path, new.title, new.title || ' ' || new.detail);
END;
CREATE TRIGGER IF NOT EXISTS search_backlog_ad AFTER DELETE ON backlog_items BEGIN
  DELETE FROM search_index WHERE kind = 'backlog' AND ref_id = old.id;
END;

CREATE TRIGGER IF NOT EXISTS search_learnings_ai AFTER INSERT ON learnings BEGIN
  INSERT INTO search_index (kind, ref_id, scope, title, body)
  VALUES ('learning', new.id, new.repo_path, new.text, new.text);
END;
CREATE TRIGGER IF NOT EXISTS search_learnings_au AFTER UPDATE ON learnings BEGIN
  DELETE FROM search_index WHERE kind = 'learning' AND ref_id = old.id;
  INSERT INTO search_index (kind, ref_id, scope, title, body)
  VALUES ('learning', new.id, new.repo_path, new.text, new.text);
END;
CREATE TRIGGER IF NOT EXISTS search_learnings_ad AFTER DELETE ON learnings BEGIN
  DELETE FROM search_index WHERE kind = 'learning' AND ref_id = old.id;
END;
`

export class NodeSqliteDb implements Db {
  /** Nesting depth, so only the outermost call owns BEGIN/COMMIT. */
  private depth = 0

  constructor(private readonly handle: DatabaseSync) {}

  exec(sql: string): void {
    this.handle.exec(sql)
  }

  run(sql: string, ...params: unknown[]): { changes: number } {
    const stmt = this.handle.prepare(sql)
    const result = stmt.run(...(params as never[]))
    return { changes: Number(result.changes ?? 0) }
  }

  get<T = Row>(sql: string, ...params: unknown[]): T | undefined {
    const stmt = this.handle.prepare(sql)
    return stmt.get(...(params as never[])) as T | undefined
  }

  all<T = Row>(sql: string, ...params: unknown[]): T[] {
    const stmt = this.handle.prepare(sql)
    return stmt.all(...(params as never[])) as T[]
  }

  /**
   * Wraps `fn` in a transaction. Used for the multi-statement writes that must
   * not half-apply — recording a verdict with its findings, or consuming an
   * approval at the same moment a milestone flips to executing.
   *
   * Re-entrant: only the outermost call issues BEGIN and COMMIT, and an error
   * anywhere inside rolls the whole thing back. SQLite refuses a nested BEGIN,
   * and that refusal has twice forced a method to be split into a
   * transaction-free `-Core` variant purely so a caller could wrap it —
   * createPlanCore and fileBacklogItemCore both exist for that reason and for
   * no other. Nesting previously threw, so nothing in the codebase nests
   * today; making it work can only enable calls that were impossible, never
   * change one that already ran.
   */
  transaction<T>(fn: () => T): T {
    if (this.depth > 0) {
      // Already inside one. Joining it is the point: the outermost call owns
      // the commit, so a failure here still takes everything down with it.
      this.depth += 1
      try {
        return fn()
      } finally {
        this.depth -= 1
      }
    }

    this.handle.exec('BEGIN')
    this.depth = 1
    try {
      const value = fn()
      this.depth = 0
      this.handle.exec('COMMIT')
      return value
    } catch (err) {
      this.depth = 0
      try {
        this.handle.exec('ROLLBACK')
      } catch {
        // A failed rollback would mask the original error; keep that one.
      }
      throw err
    }
  }

  close(): void {
    this.handle.close()
  }
}

export function openDatabase(path: string): Db {
  if (path !== ':memory:') mkdirSync(dirname(path), { recursive: true })

  const handle = new DatabaseSync(path)
  const db = new NodeSqliteDb(handle)

  // WAL keeps reads from blocking the orchestrator's writes while a session
  // streams. foreign_keys is off by default in SQLite and the cascades above
  // rely on it.
  db.exec('PRAGMA journal_mode = WAL')
  db.exec('PRAGMA foreign_keys = ON')
  db.exec('PRAGMA busy_timeout = 5000')

  migrate(db)
  return db
}

export function migrate(db: Db): void {
  db.exec(SCHEMA)
  const row = db.get<{ value: string }>(`SELECT value FROM meta WHERE key = 'schema_version'`)
  const current = row ? Number(row.value) : 0

  // A fresh database runs every block (current is 0), and since v16 removed
  // the two-sided legacy columns from SCHEMA, any statement that reads one
  // must first check the column exists — on a fresh database it never will.
  const hasColumn = (table: string, column: string): boolean =>
    db.get(`SELECT name FROM pragma_table_info(?) WHERE name = ?`, table, column) !== undefined
  if (current === SCHEMA_VERSION) return
  if (current > SCHEMA_VERSION) {
    throw new Error(
      `database schema is version ${current} but this build understands ${SCHEMA_VERSION}; refusing to downgrade`,
    )
  }
  // Version 1 is the initial schema, created by SCHEMA above. Later versions add
  // their ALTERs here, guarded on `current`.
  if (current < 2) {
    // Records made before this column existed predate mock-mode tracking. They
    // default to 0 (real), which is the safe reading: the mock adapters were
    // opt-in, and marking genuine work as fake would be the worse error.
    for (const table of ['sessions', 'plans', 'loops']) {
      try {
        db.exec(`ALTER TABLE ${table} ADD COLUMN mock INTEGER NOT NULL DEFAULT 0`)
      } catch {
        // Already present, because SCHEMA above created the table fresh.
      }
    }
  }
  if (current < 3) {
    try {
      db.exec(`ALTER TABLE milestones ADD COLUMN adopted INTEGER NOT NULL DEFAULT 0`)
    } catch {
      // Already present, because SCHEMA above created the table fresh.
    }
  }
  if (current < 5) {
    for (const column of [
      `question TEXT NOT NULL DEFAULT ''`,
      `correction_note TEXT NOT NULL DEFAULT ''`,
      `pending TEXT`,
    ]) {
      try {
        db.exec(`ALTER TABLE plans ADD COLUMN ${column}`)
      } catch {
        // Already present on a database created fresh from SCHEMA.
      }
    }
  }
  if (current < 4) {
    // Created by SCHEMA above on a fresh database; nothing to alter on an
    // existing one because the table is additive.
  }
  if (current < 6) {
    try {
      // NULL means "not archived", so every existing session stays visible.
      db.exec(`ALTER TABLE sessions ADD COLUMN archived_at INTEGER`)
    } catch {
      // Already present on a database created fresh from SCHEMA.
    }
  }
  if (current < 7) {
    // Milestones planned before mutation checks existed simply declare none,
    // which reads correctly: nothing was claimed, so nothing went unproven.
    for (const column of [
      `mutations TEXT NOT NULL DEFAULT '[]'`,
      `mutation_results TEXT NOT NULL DEFAULT '[]'`,
    ]) {
      try {
        db.exec(`ALTER TABLE milestones ADD COLUMN ${column}`)
      } catch {
        // Already present on a database created fresh from SCHEMA.
      }
    }
  }
  if (current < 8) {
    // The review already separated blocking findings from mere notes, and the
    // planner's dispositions were already structured — both were flattened into
    // prose on the way into the database, so the surface had nothing to render
    // differently. Stored as JSON now; rows written before this simply have none,
    // and their prose note still displays.
    for (const column of [
      `review_blocking TEXT NOT NULL DEFAULT '[]'`,
      `review_notes TEXT NOT NULL DEFAULT '[]'`,
    ]) {
      try {
        db.exec(`ALTER TABLE milestones ADD COLUMN ${column}`)
      } catch {
        // Already present on a database created fresh from SCHEMA.
      }
    }
    try {
      db.exec(`ALTER TABLE plans ADD COLUMN correction_dispositions TEXT NOT NULL DEFAULT '[]'`)
    } catch {
      // Already present on a database created fresh from SCHEMA.
    }
  }
  if (current < 9) {
    // The finding ledger is additive. SCHEMA creates its three tables before
    // the recorded version is inspected, leaving every version-8 row intact.
  }
  if (current < 10) {
    db.transaction(() => {
      for (const table of ['ledger_sightings', 'ledger_dispositions']) {
        try {
          db.exec(`ALTER TABLE ${table} ADD COLUMN seq INTEGER NOT NULL DEFAULT 0`)
        } catch {
          // Already present, because SCHEMA above created the table fresh.
        }
      }

      const rankedLedger = `
        SELECT entry_kind, id,
               ROW_NUMBER() OVER (ORDER BY created_at ASC, id ASC) AS seq
        FROM (
          SELECT 'sighting' AS entry_kind, id, created_at FROM ledger_sightings
          UNION ALL
          SELECT 'disposition' AS entry_kind, id, created_at FROM ledger_dispositions
        )
      `
      db.exec(`
        WITH ranked AS (${rankedLedger})
        UPDATE ledger_sightings
        SET seq = (
          SELECT ranked.seq
          FROM ranked
          WHERE ranked.entry_kind = 'sighting'
            AND ranked.id = ledger_sightings.id
        )
      `)
      db.exec(`
        WITH ranked AS (${rankedLedger})
        UPDATE ledger_dispositions
        SET seq = (
          SELECT ranked.seq
          FROM ranked
          WHERE ranked.entry_kind = 'disposition'
            AND ranked.id = ledger_dispositions.id
        )
      `)

      db.exec(`DROP INDEX IF EXISTS idx_ledger_sightings_finding`)
      db.exec(`DROP INDEX IF EXISTS idx_ledger_dispositions_finding`)
      db.exec(`DROP INDEX IF EXISTS idx_ledger_dispositions_occurrence`)
      db.exec(`
        CREATE INDEX idx_ledger_sightings_finding
        ON ledger_sightings(finding_id, seq)
      `)
      db.exec(`
        CREATE INDEX idx_ledger_dispositions_finding
        ON ledger_dispositions(finding_id, seq)
      `)
      db.exec(`
        CREATE INDEX idx_ledger_dispositions_occurrence
        ON ledger_dispositions(occurrence_id, seq)
      `)
    })
  }
  if (current < 11) {
    // Participants become data: every existing two-sided session backfills as
    // seats 0 and 1. agent_a and agent_b hold JSON objects, so concatenation
    // builds the array without parsing them — and the columns stay in place as
    // the legacy read fallback.
    db.transaction(() => {
      try {
        db.exec(`ALTER TABLE sessions ADD COLUMN participants TEXT`)
      } catch {
        // Already present, because SCHEMA above created the table fresh.
      }
      if (hasColumn('sessions', 'agent_a')) {
        db.exec(
          `UPDATE sessions
           SET participants = '[' || agent_a || ',' || agent_b || ']'
           WHERE participants IS NULL`,
        )
      }
    })
  }
  if (current < 12) {
    // Turns and threads speak seats. Turns gain the seat column beside the
    // mirrored side name; agent_threads is rebuilt outright because its
    // primary key changes from (session_id, side) to (session_id, seat), and
    // SQLite cannot alter a primary key in place. Thread rows are transient
    // resume handles, but they are cheap to carry across, so they are.
    db.transaction(() => {
      try {
        db.exec(`ALTER TABLE turns ADD COLUMN seat INTEGER`)
      } catch {
        // Already present, because SCHEMA above created the table fresh.
      }
      if (hasColumn('turns', 'side')) {
        db.exec(
          `UPDATE turns
           SET seat = CASE side WHEN 'a' THEN 0 WHEN 'b' THEN 1 ELSE CAST(side AS INTEGER) END
           WHERE seat IS NULL`,
        )
      }

      const legacyThreads = db.get(
        `SELECT name FROM pragma_table_info('agent_threads') WHERE name = 'side'`,
      )
      if (legacyThreads) {
        db.exec(`
          CREATE TABLE agent_threads_seated (
            session_id TEXT NOT NULL,
            seat       INTEGER NOT NULL,
            resume_id  TEXT NOT NULL,
            PRIMARY KEY (session_id, seat)
          );
        `)
        db.exec(`
          INSERT INTO agent_threads_seated (session_id, seat, resume_id)
          SELECT session_id,
                 CASE side WHEN 'a' THEN 0 WHEN 'b' THEN 1 ELSE CAST(side AS INTEGER) END,
                 resume_id
          FROM agent_threads
        `)
        db.exec(`DROP TABLE agent_threads`)
        db.exec(`ALTER TABLE agent_threads_seated RENAME TO agent_threads`)
      }
    })
  }
  if (current < 13) {
    // Decision holds are additive: SCHEMA creates hold_acks and
    // hold_notifications fresh, and no existing row changes shape.
  }
  if (current < 14) {
    // The worktrees table is additive (SCHEMA creates it fresh). Existing
    // plans backfill as checkout isolation — exactly what they were.
    for (const column of [
      `isolation TEXT NOT NULL DEFAULT 'checkout'`,
      `setup_command TEXT NOT NULL DEFAULT ''`,
    ]) {
      try {
        db.exec(`ALTER TABLE plans ADD COLUMN ${column}`)
      } catch {
        // Already present, because SCHEMA above created the table fresh.
      }
    }
  }
  if (current < 15) {
    // Whisper delivery becomes per-seat rows (SCHEMA created the table fresh).
    // The two per-side stamps backfill as seats 0 and 1.
    if (hasColumn('interjections', 'delivered_a_at')) {
      db.transaction(() => {
        db.exec(`
          INSERT OR IGNORE INTO interjection_deliveries (interjection_id, seat, delivered_at)
          SELECT id, 0, delivered_a_at FROM interjections WHERE delivered_a_at IS NOT NULL
        `)
        db.exec(`
          INSERT OR IGNORE INTO interjection_deliveries (interjection_id, seat, delivered_at)
          SELECT id, 1, delivered_b_at FROM interjections WHERE delivered_b_at IS NOT NULL
        `)
      })
    }
  }
  if (current < 16) {
    // The two-sided mirrors retire. They existed for older builds reading this
    // database — but the version stamp below makes an older build refuse it
    // outright, so from here they were columns nothing would ever read again.
    // Their contents were backfilled into participants (v11), seat (v12) and
    // interjection_deliveries (v15) before this runs.
    db.transaction(() => {
      for (const [table, column] of [
        ['sessions', 'agent_a'],
        ['sessions', 'agent_b'],
        ['turns', 'side'],
        ['interjections', 'delivered_a_at'],
        ['interjections', 'delivered_b_at'],
      ] as const) {
        if (hasColumn(table, column)) db.exec(`ALTER TABLE ${table} DROP COLUMN ${column}`)
      }
    })
  }
  if (current < 17) {
    // Run recovery is additive: milestones gain the run-state blob, loops the
    // liveness stamp. Existing rows read NULL — nothing was resumable before
    // this existed, which is exactly what NULL means.
    for (const [table, column] of [
      ['milestones', `run_state TEXT`],
      ['loops', `last_activity_at INTEGER`],
    ] as const) {
      try {
        db.exec(`ALTER TABLE ${table} ADD COLUMN ${column}`)
      } catch {
        // Already present, because SCHEMA above created the table fresh.
      }
    }
  }
  if (current < 18) {
    // The backlog is additive: SCHEMA creates backlog_items, backlog_events
    // and learnings fresh, and no existing row changes shape.
  }
  if (current < 19) {
    // The foreman is additive: SCHEMA creates foreman_proposals fresh, and
    // no existing row changes shape.
  }
  if (current < 20) {
    // Self-update is additive: SCHEMA creates self_updates fresh, and no
    // existing row changes shape. plan_id is deliberately FK-less — session
    // deletion cascades to plans, and the record must outlive its plan.
  }
  if (current < 21) {
    // Repository activity and archive watermarks are additive. SCHEMA creates
    // both tables before the stored version is read, preserving existing rows.
  }
  if (current < 22) {
    // repo_containers is additive (SCHEMA creates it fresh). The snapshot
    // columns join two existing tables; every pre-existing row keeps host
    // execution, which is what its approval meant.
    for (const table of ['plans', 'loops']) {
      try {
        db.exec(`ALTER TABLE ${table} ADD COLUMN container INTEGER NOT NULL DEFAULT 0`)
      } catch {
        // Already present, because SCHEMA above created the table fresh.
      }
    }
  }
  if (current < 23) {
    // Envelopes are additive: SCHEMA creates the table fresh, and no
    // existing row changes shape.
  }
  if (current < 24) {
    // Workspaces are additive: SCHEMA creates the table fresh, and no
    // existing row changes shape.
  }
  if (current < 25) {
    // acceptances is additive. The provenance column joins an existing table,
    // and every pre-existing item keeps a null — they came from somewhere
    // else, which is exactly what null says here.
    try {
      db.exec(`ALTER TABLE backlog_items ADD COLUMN origin_acceptance_id TEXT`)
    } catch {
      // Already present, because SCHEMA above created the table fresh.
    }
  }
  if (current < 26) {
    // app_journeys is additive: SCHEMA creates the table fresh, and no
    // existing row changes shape.
  }
  if (current < 27) {
    // remote_targets is additive: SCHEMA creates the table fresh, and no
    // existing row changes shape.
  }
  if (current < 28) {
    // run_events is additive: SCHEMA creates the table and its indexes fresh,
    // and no existing row changes shape. Runs before this version have no
    // journal and never will — the facts were not kept.
  }
  if (current < 29) {
    // Sightings recorded before this carry no reference and never will: the
    // reviewer was not asked for one. The default makes them read as "said
    // nothing about where", which is exactly true.
    try {
      db.exec(`ALTER TABLE ledger_sightings ADD COLUMN evidence TEXT NOT NULL DEFAULT '[]'`)
    } catch {
      // Already present, because SCHEMA above created the table fresh.
    }
  }
  if (current < 30) {
    // SCHEMA created the table and its triggers above; the triggers only fire
    // on writes from here on, so everything already recorded has to be swept
    // in once. Backfilling from the sources rather than asking anyone to
    // re-enter anything: the text is all there, it has simply never been
    // indexed.
    db.exec(`DELETE FROM search_index`)
    db.exec(`INSERT INTO search_index (kind, ref_id, scope, title, body)
             SELECT 'session', id, id, matter, matter || ' ' || project FROM sessions`)
    db.exec(`INSERT INTO search_index (kind, ref_id, scope, title, body)
             SELECT 'turn', id, session_id, vendor || ' · ' || stage, text FROM turns`)
    db.exec(`INSERT INTO search_index (kind, ref_id, scope, title, body)
             SELECT 'plan', id, repo_path, title, title || ' ' || question FROM plans`)
    db.exec(`INSERT INTO search_index (kind, ref_id, scope, title, body)
             SELECT 'milestone', id, plan_id, title,
                    title || ' ' || intent || ' ' || review_note || ' ' || audit_note
             FROM milestones`)
    db.exec(`INSERT INTO search_index (kind, ref_id, scope, title, body)
             SELECT 'finding', id, session_id, text, text FROM ledger_findings`)
    db.exec(`INSERT INTO search_index (kind, ref_id, scope, title, body)
             SELECT 'backlog', id, repo_path, title, title || ' ' || detail FROM backlog_items`)
    db.exec(`INSERT INTO search_index (kind, ref_id, scope, title, body)
             SELECT 'learning', id, repo_path, text, text FROM learnings`)
  }
  if (current < 31) {
    // Additive: SCHEMA creates the table fresh. Runs that disconnected before
    // this existed are unrecoverable and always were — nothing recorded where
    // they went.
  }
  if (current < 32) {
    // agent_profiles is additive. run_events grows the actor's profile
    // column; events recorded before profiles existed read as unstamped,
    // which is exactly what they were.
    try {
      db.exec(`ALTER TABLE run_events ADD COLUMN actor_profile TEXT`)
    } catch {
      // Already present, because SCHEMA above created the table fresh.
    }
  }
  db.run(
    `INSERT INTO meta (key, value) VALUES ('schema_version', ?)
     ON CONFLICT(key) DO UPDATE SET value = excluded.value`,
    String(SCHEMA_VERSION),
  )
}
