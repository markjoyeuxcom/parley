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

export const SCHEMA_VERSION = 35

const SCHEMA = `
CREATE TABLE IF NOT EXISTS meta (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
















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















-- No foreign key, following self_updates and envelopes: a run record should
-- outlive the plan a session deletion cascades away. What happened happened,
-- and losing the account of it because its subject was tidied up would defeat
-- the reason for keeping one.

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




-- A run that left this machine, and whether we ever found out how it went.
--
-- Written after the snapshot is pushed and before anything is spent, because
-- that is the window in which a run becomes recoverable: from then on a dead
-- connection can hide a run that FINISHED, and every value needed to go back
-- and look — which host, which mirror, which commit was submitted — is a
-- local variable that vanishes with the call.
--

-- A free-flow room, and everything said in it.
--
-- Its own tables rather than the sessions/turns pair, which ROOMS.md planned
-- for and which the room model then argued out of. The columns do not fit: a
-- human turn has no vendor and turns.vendor is NOT NULL; turns.seat is an
-- integer index into a two-sided seating order while a room seat has a name;
-- sessions.matter is the question a debate exists to settle and a room has
-- none. Every one of those is survivable alone and together they would make
-- rooms a tenant of a schema shaped for something else — which matters
-- because the sessions tables are scheduled for deletion, and a repurposed
-- half of them would have to survive as legacy rather than going with the
-- rest.
--
-- Only what cannot be recomputed is stored. Turns spent is the count of agent
-- turns, usage is their sum, and status is idle unless the caps are spent —
-- so none of them are columns, and none of them can drift from the turns they
-- summarise. The same rule the holds queue and the in-flight list follow.
CREATE TABLE IF NOT EXISTS rooms (
  id         TEXT PRIMARY KEY,
  cwd        TEXT NOT NULL,
  -- RoomSeat[] as JSON: id, address name, and the seat's config.
  seats      TEXT NOT NULL,
  caps       TEXT NOT NULL,
  mock       INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL,
  -- When its pane was closed. The record survives: a long room is hours of
  -- reading and real money, and closing a pane is not a decision to destroy
  -- it. Startup drops only the ones that never held a turn.
  closed_at  INTEGER
);
CREATE INDEX IF NOT EXISTS idx_rooms_created ON rooms(created_at DESC);

CREATE TABLE IF NOT EXISTS room_turns (
  id         TEXT PRIMARY KEY,
  room_id    TEXT NOT NULL REFERENCES rooms(id) ON DELETE CASCADE,
  idx        INTEGER NOT NULL,
  author     TEXT NOT NULL,
  -- The seat's name as of this turn, empty for a human. A name and not an id
  -- for the journal's reason: what a seat was called when it spoke is a fact
  -- that outlives the seat being renamed or removed.
  seat       TEXT NOT NULL DEFAULT '',
  vendor     TEXT,
  profile    TEXT NOT NULL DEFAULT '',
  text       TEXT NOT NULL DEFAULT '',
  usage      TEXT NOT NULL,
  started_at INTEGER NOT NULL,
  ended_at   INTEGER,
  error      TEXT
);
CREATE INDEX IF NOT EXISTS idx_room_turns_room ON room_turns(room_id, idx);

-- What a room's seats concluded, when somebody asked them to.
--
-- Its own id rather than one row per room: a conversation can reach several
-- conclusions over its life, and overwriting the first the moment a second is
-- asked for would destroy the more interesting half of the record — what they
-- thought before, and what changed their minds. The sessions-era verdicts
-- table keys on session_id and could hold only one; that was a limit nobody
-- noticed because a debate ended when its schedule did.
CREATE TABLE IF NOT EXISTS room_verdicts (
  id            TEXT PRIMARY KEY,
  room_id       TEXT NOT NULL REFERENCES rooms(id) ON DELETE CASCADE,
  question      TEXT NOT NULL DEFAULT '',
  decision      TEXT NOT NULL,
  rationale     TEXT NOT NULL DEFAULT '',
  scores        TEXT NOT NULL,
  confidence    REAL NOT NULL,
  -- Kept beside the confidence it already lowered, so a surface can say the
  -- seats disagreed rather than only showing the reduced number.
  agreement     REAL NOT NULL DEFAULT 0,
  single_source INTEGER NOT NULL DEFAULT 0,
  dissent       TEXT NOT NULL DEFAULT '',
  report        TEXT NOT NULL,
  created_at    INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_room_verdicts_room ON room_verdicts(room_id, created_at DESC);

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








-- A room turn is indexed by the seat that said it, scoped to its room. The
-- text arrives empty on insert and is filled when the turn ends, so the
-- update trigger is the one that does the real work here.
CREATE TRIGGER IF NOT EXISTS search_room_turns_ai AFTER INSERT ON room_turns BEGIN
  INSERT INTO search_index (kind, ref_id, scope, title, body)
  VALUES ('room-turn', new.id, new.room_id,
          CASE WHEN new.author = 'human' THEN 'You' ELSE '@' || new.seat END, new.text);
END;
CREATE TRIGGER IF NOT EXISTS search_room_turns_au AFTER UPDATE ON room_turns BEGIN
  DELETE FROM search_index WHERE kind = 'room-turn' AND ref_id = old.id;
  INSERT INTO search_index (kind, ref_id, scope, title, body)
  VALUES ('room-turn', new.id, new.room_id,
          CASE WHEN new.author = 'human' THEN 'You' ELSE '@' || new.seat END, new.text);
END;
CREATE TRIGGER IF NOT EXISTS search_room_turns_ad AFTER DELETE ON room_turns BEGIN
  DELETE FROM search_index WHERE kind = 'room-turn' AND ref_id = old.id;
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
  // The ladder starts at 35.
  //
  // Every earlier step migrated a table this version drops, so there is
  // nothing below here for them to preserve: a database older than 33 predates
  // rooms entirely and holds only the governed engine's records, and one at 33
  // or 34 keeps its rooms through the drop below. Keeping thirty dead ALTERs
  // that reference tables SCHEMA no longer creates would mean a fresh database
  // running statements against tables that do not exist, guarded by try/catch
  // — which is how a migration stops meaning anything.
  if (current > 0 && current < 35) {
    // Dropping rows is the one part of the Rooms arc git cannot undo. What
    // was checked before writing it: the only databases in existence were
    // empty. Anyone arriving here with real sessions, plans or a backlog
    // should export first — no reader for any of it survives in the app, and
    // this is how that becomes true of the file as well.
    // Foreign keys off for the duration: these tables reference each other,
    // and dropping a parent before its child is a constraint error that a
    // catch would swallow — which it did, leaving ledger_sightings behind
    // and the migration reporting success. They are all going; the graph
    // between them is not worth ordering by hand.
    db.exec('PRAGMA foreign_keys = OFF')
    for (const table of ['sessions', 'turns', 'agent_threads', 'interjections', 'interjection_deliveries', 'verdicts', 'findings', 'ledger_findings', 'ledger_sightings', 'ledger_dispositions', 'plans', 'milestones', 'approvals', 'loops', 'loop_iterations', 'hold_acks', 'hold_notifications', 'worktrees', 'backlog_items', 'backlog_events', 'learnings', 'foreman_proposals', 'self_updates', 'repo_activity', 'repo_archives', 'repo_containers', 'envelopes', 'acceptances', 'run_events', 'remote_targets', 'app_journeys', 'workspaces', 'remote_runs']) {
      try {
        db.exec(`DROP TABLE IF EXISTS ${table}`)
      } catch {
        // A table that will not drop is not a reason to refuse to start.
      }
    }
    db.exec('PRAGMA foreign_keys = ON')
    // The index outlives its sources; sweep what those tables put in it.
    try {
      db.run(`DELETE FROM search_index WHERE kind <> 'room-turn'`)
    } catch {
      // A fresh index has nothing to sweep.
    }
  }

  db.run(
    `INSERT INTO meta (key, value) VALUES ('schema_version', ?)
     ON CONFLICT(key) DO UPDATE SET value = excluded.value`,
    String(SCHEMA_VERSION),
  )
}
