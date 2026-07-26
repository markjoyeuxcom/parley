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

export const SCHEMA_VERSION = 9

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
  agent_a    TEXT NOT NULL,
  agent_b    TEXT NOT NULL,
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
  side       TEXT NOT NULL,
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
  side       TEXT NOT NULL,
  resume_id  TEXT NOT NULL,
  PRIMARY KEY (session_id, side)
);

-- Delivery is tracked per side, not once per row. A 'both' interjection has to
-- reach each agent exactly once, and the two sides take their turns at
-- different times, so a single delivered_at would let whichever side read it
-- first swallow the message.
CREATE TABLE IF NOT EXISTS interjections (
  id             TEXT PRIMARY KEY,
  session_id     TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  target         TEXT NOT NULL,
  text           TEXT NOT NULL,
  at_turn_index  INTEGER NOT NULL,
  created_at     INTEGER NOT NULL,
  delivered_a_at INTEGER,
  delivered_b_at INTEGER
);
CREATE INDEX IF NOT EXISTS idx_interject_session ON interjections(session_id, created_at);

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
  created_at   INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_ledger_sightings_finding
  ON ledger_sightings(finding_id, created_at);

CREATE TABLE IF NOT EXISTS ledger_dispositions (
  id            TEXT PRIMARY KEY,
  finding_id    TEXT NOT NULL REFERENCES ledger_findings(id) ON DELETE CASCADE,
  occurrence_id TEXT REFERENCES ledger_sightings(id) ON DELETE CASCADE,
  state         TEXT NOT NULL,
  note          TEXT NOT NULL DEFAULT '',
  source        TEXT NOT NULL,
  created_at    INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_ledger_dispositions_finding
  ON ledger_dispositions(finding_id, created_at);
CREATE INDEX IF NOT EXISTS idx_ledger_dispositions_occurrence
  ON ledger_dispositions(occurrence_id, created_at);

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
  review_notes     TEXT NOT NULL DEFAULT '[]'
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
  approval_id     TEXT,
  status          TEXT NOT NULL,
  usage           TEXT NOT NULL,
  iteration_count INTEGER NOT NULL DEFAULT 0,
  mock            INTEGER NOT NULL DEFAULT 0,
  started_at      INTEGER NOT NULL,
  ended_at        INTEGER,
  stop_reason     TEXT NOT NULL DEFAULT ''
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
`

class NodeSqliteDb implements Db {
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
   */
  transaction<T>(fn: () => T): T {
    this.handle.exec('BEGIN')
    try {
      const value = fn()
      this.handle.exec('COMMIT')
      return value
    } catch (err) {
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
  db.run(
    `INSERT INTO meta (key, value) VALUES ('schema_version', ?)
     ON CONFLICT(key) DO UPDATE SET value = excluded.value`,
    String(SCHEMA_VERSION),
  )
}
