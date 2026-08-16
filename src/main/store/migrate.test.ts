import { describe, expect, it } from 'vitest'
import { DatabaseSync } from 'node:sqlite'
import { migrate, openDatabase, SCHEMA_VERSION } from './db'
import type { Db } from './db'

/**
 * Opening a database that is not this version.
 *
 * The ladder has one rung now: everything the governed engine wrote is
 * dropped, and what a room wrote survives. The properties worth pinning are
 * that the drop is not selective about which old version it came from, that
 * rooms come through it, and that a newer database is still refused rather
 * than silently downgraded.
 */

function wrap(db: DatabaseSync): Db {
  return {
    exec: (sql) => db.exec(sql),
    run: (sql, ...params) => db.prepare(sql).run(...(params as never[])) as { changes: number },
    get: (sql, ...params) => db.prepare(sql).get(...(params as never[])) as never,
    all: (sql, ...params) => db.prepare(sql).all(...(params as never[])) as never[],
    transaction: (fn) => fn(),
    close: () => db.close(),
  }
}

describe('migrate', () => {
  it('creates the current schema on a fresh database', () => {
    const db = openDatabase(':memory:')
    const tables = db
      .all<{ name: string }>(`SELECT name FROM sqlite_schema WHERE type = 'table'`)
      .map((row) => row.name)
    expect(tables).toContain('rooms')
    expect(tables).toContain('room_turns')
    expect(tables).toContain('room_verdicts')
    expect(db.get<{ value: string }>(`SELECT value FROM meta WHERE key = 'schema_version'`)?.value).toBe(
      String(SCHEMA_VERSION),
    )
  })

  it('drops the governed tables and keeps the rooms', () => {
    // A version-34 database: rooms already existed beside the engine, and
    // only the engine goes.
    const raw = new DatabaseSync(':memory:')
    const db = wrap(raw)
    db.exec(`
      CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
      CREATE TABLE sessions (id TEXT PRIMARY KEY, matter TEXT NOT NULL);
      CREATE TABLE plans (id TEXT PRIMARY KEY, title TEXT NOT NULL);
      CREATE TABLE rooms (
        id TEXT PRIMARY KEY, cwd TEXT NOT NULL, seats TEXT NOT NULL,
        caps TEXT NOT NULL, mock INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL, closed_at INTEGER
      );
    `)
    db.run(`INSERT INTO meta (key, value) VALUES ('schema_version', '34')`)
    db.run(`INSERT INTO sessions (id, matter) VALUES ('s1', 'a debate')`)
    db.run(`INSERT INTO plans (id, title) VALUES ('p1', 'a plan')`)
    db.run(
      `INSERT INTO rooms (id, cwd, seats, caps, mock, created_at) VALUES ('r1', '/tmp', '[]', '{}', 0, 1)`,
    )

    migrate(db)

    const tables = new Set(
      db.all<{ name: string }>(`SELECT name FROM sqlite_schema WHERE type = 'table'`).map((r) => r.name),
    )
    expect(tables.has('sessions')).toBe(false)
    expect(tables.has('plans')).toBe(false)
    // The conversation survives its neighbours.
    expect(db.get<{ id: string }>(`SELECT id FROM rooms`)?.id).toBe('r1')
  })

  it('drops from any earlier version, not just the last one', () => {
    // A database that predates rooms holds nothing the app can still read.
    const raw = new DatabaseSync(':memory:')
    const db = wrap(raw)
    db.exec(`
      CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
      CREATE TABLE loops (id TEXT PRIMARY KEY, goal TEXT NOT NULL);
    `)
    db.run(`INSERT INTO meta (key, value) VALUES ('schema_version', '8')`)
    db.run(`INSERT INTO loops (id, goal) VALUES ('l1', 'get the suite green')`)

    migrate(db)

    const tables = new Set(
      db.all<{ name: string }>(`SELECT name FROM sqlite_schema WHERE type = 'table'`).map((r) => r.name),
    )
    expect(tables.has('loops')).toBe(false)
    expect(tables.has('rooms')).toBe(true)
  })

  it('drops a table whose parent went first', () => {
    // The ledger tables reference each other. Dropping a parent before its
    // child raises a constraint error, and the catch that keeps a bad table
    // from stopping startup swallowed it — leaving the child behind while the
    // migration reported success. Foreign keys are off for the duration now.
    const raw = new DatabaseSync(':memory:')
    const db = wrap(raw)
    db.exec(`PRAGMA foreign_keys = ON`)
    db.exec(`
      CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
      CREATE TABLE ledger_findings (id TEXT PRIMARY KEY);
      CREATE TABLE ledger_sightings (
        id TEXT PRIMARY KEY,
        finding_id TEXT NOT NULL REFERENCES ledger_findings(id) ON DELETE CASCADE
      );
    `)
    db.run(`INSERT INTO meta (key, value) VALUES ('schema_version', '34')`)

    migrate(db)

    const tables = new Set(
      db.all<{ name: string }>(`SELECT name FROM sqlite_schema WHERE type = 'table'`).map((r) => r.name),
    )
    expect(tables.has('ledger_findings')).toBe(false)
    expect(tables.has('ledger_sightings')).toBe(false)
  })

  it('refuses a database written by a newer build', () => {
    // The dev checkout migrates ahead of any frozen install; opening the
    // newer record with older code would be a silent downgrade.
    const raw = new DatabaseSync(':memory:')
    const db = wrap(raw)
    db.exec(`CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)`)
    db.run(`INSERT INTO meta (key, value) VALUES ('schema_version', ?)`, String(SCHEMA_VERSION + 1))
    expect(() => migrate(db)).toThrow(/refusing to downgrade/)
  })
})
