import { describe, expect, it } from 'vitest'
import { migrate, openDatabase, SCHEMA_VERSION } from './db'

describe('schema migrations', () => {
  it('upgrades a populated version-8 database with its rows intact', () => {
    const db = openDatabase(':memory:')
    // Reconstruct the era's pair columns, which v16 removed from head.
    db.exec(`ALTER TABLE sessions ADD COLUMN agent_a TEXT`)
    db.exec(`ALTER TABLE sessions ADD COLUMN agent_b TEXT`)
    db.run(
      `INSERT INTO sessions
       (id, kind, status, matter, project, repo_path, agent_a, agent_b, max_turns, usage, mock, created_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      'session-v8',
      'debate',
      'complete',
      'history from schema 8',
      '',
      null,
      '{}',
      '{}',
      6,
      '{}',
      0,
      10,
    )
    db.run(
      `INSERT INTO findings
       (id, session_id, priority, status, title, detail, evidence, raised_by, created_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      'legacy-finding',
      'session-v8',
      'high',
      'confirmed',
      'Existing verdict finding',
      '',
      '[]',
      'a',
      11,
    )

    db.exec(`DROP TABLE ledger_dispositions`)
    db.exec(`DROP TABLE ledger_sightings`)
    db.exec(`DROP TABLE ledger_findings`)
    db.run(`UPDATE meta SET value = '8' WHERE key = 'schema_version'`)

    expect(
      db.get(`SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'ledger_findings'`),
    ).toBeUndefined()

    migrate(db)

    expect(db.get<{ value: string }>(`SELECT value FROM meta WHERE key = 'schema_version'`)?.value).toBe(
      // The head version, never a literal - a hardcoded number fails on every
      // future migration for a reason unrelated to what this test checks.
      String(SCHEMA_VERSION),
    )
    expect(db.get<{ matter: string }>(`SELECT matter FROM sessions WHERE id = 'session-v8'`)?.matter).toBe(
      'history from schema 8',
    )
    expect(
      db.get<{ title: string }>(`SELECT title FROM findings WHERE id = 'legacy-finding'`)?.title,
    ).toBe('Existing verdict finding')
    for (const table of ['ledger_findings', 'ledger_sightings', 'ledger_dispositions']) {
      expect(
        db.get(`SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?`, table),
      ).toBeTruthy()
    }
  })

  it('backfills version-9 ledger rows into one deterministic global sequence', () => {
    const db = openDatabase(':memory:')
    db.exec(`
      DROP TABLE ledger_dispositions;
      DROP TABLE ledger_sightings;

      CREATE TABLE ledger_sightings (
        id           TEXT PRIMARY KEY,
        finding_id   TEXT NOT NULL REFERENCES ledger_findings(id) ON DELETE CASCADE,
        plan_id      TEXT NOT NULL,
        milestone_id TEXT,
        round        INTEGER,
        kind         TEXT NOT NULL,
        source       TEXT NOT NULL,
        created_at   INTEGER NOT NULL
      );
      CREATE INDEX idx_ledger_sightings_finding
        ON ledger_sightings(finding_id, created_at);

      CREATE TABLE ledger_dispositions (
        id            TEXT PRIMARY KEY,
        finding_id    TEXT NOT NULL REFERENCES ledger_findings(id) ON DELETE CASCADE,
        occurrence_id TEXT REFERENCES ledger_sightings(id) ON DELETE CASCADE,
        state         TEXT NOT NULL,
        note          TEXT NOT NULL DEFAULT '',
        source        TEXT NOT NULL,
        created_at    INTEGER NOT NULL
      );
      CREATE INDEX idx_ledger_dispositions_finding
        ON ledger_dispositions(finding_id, created_at);
      CREATE INDEX idx_ledger_dispositions_occurrence
        ON ledger_dispositions(occurrence_id, created_at);
    `)
    db.run(
      `INSERT INTO ledger_findings (id, session_id, text, normalized_text, created_at)
       VALUES (?, ?, ?, ?, ?)`,
      'finding-v9',
      'session-v9',
      'Existing ledger finding.',
      'existing ledger finding',
      1,
    )
    db.run(
      `INSERT INTO ledger_sightings
       (id, finding_id, plan_id, milestone_id, round, kind, source, created_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
      'sighting-first',
      'finding-v9',
      'plan-v9',
      'milestone-1',
      0,
      'blocking',
      'review',
      10,
    )
    for (const id of ['disposition-z', 'disposition-a']) {
      db.run(
        `INSERT INTO ledger_dispositions
         (id, finding_id, occurrence_id, state, note, source, created_at)
         VALUES (?, ?, ?, ?, ?, ?, ?)`,
        id,
        'finding-v9',
        null,
        'resolved',
        '',
        'human',
        20,
      )
    }
    db.run(
      `INSERT INTO ledger_sightings
       (id, finding_id, plan_id, milestone_id, round, kind, source, created_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
      'sighting-last',
      'finding-v9',
      'plan-v9',
      'milestone-2',
      1,
      'blocking',
      'review',
      30,
    )
    db.run(`UPDATE meta SET value = '9' WHERE key = 'schema_version'`)

    migrate(db)

    expect(db.get<{ value: string }>(`SELECT value FROM meta WHERE key = 'schema_version'`)?.value).toBe(
      // The head version, never a literal - a hardcoded number fails on every
      // future migration for a reason unrelated to what this test checks.
      String(SCHEMA_VERSION),
    )
    expect(
      db.all<{ entryKind: string; id: string; seq: number }>(
        `SELECT 'sighting' AS entryKind, id, seq FROM ledger_sightings
         UNION ALL
         SELECT 'disposition' AS entryKind, id, seq FROM ledger_dispositions
         ORDER BY seq`,
      ),
    ).toEqual([
      { entryKind: 'sighting', id: 'sighting-first', seq: 1 },
      { entryKind: 'disposition', id: 'disposition-a', seq: 2 },
      { entryKind: 'disposition', id: 'disposition-z', seq: 3 },
      { entryKind: 'sighting', id: 'sighting-last', seq: 4 },
    ])
  })

  it('adds the foreman table when upgrading from version 18', () => {
    const db = openDatabase(':memory:')
    db.exec(`DROP TABLE foreman_proposals`)
    db.run(`UPDATE meta SET value = '18' WHERE key = 'schema_version'`)

    migrate(db)

    expect(db.get<{ value: string }>(`SELECT value FROM meta WHERE key = 'schema_version'`)?.value).toBe(
      String(SCHEMA_VERSION),
    )
    expect(
      db.get(`SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'foreman_proposals'`),
    ).toBeTruthy()
  })

  it('adds the backlog tables when upgrading from version 17', () => {
    const db = openDatabase(':memory:')
    db.exec(`DROP TABLE backlog_events`)
    db.exec(`DROP TABLE backlog_items`)
    db.exec(`DROP TABLE learnings`)
    db.run(`UPDATE meta SET value = '17' WHERE key = 'schema_version'`)

    migrate(db)

    expect(db.get<{ value: string }>(`SELECT value FROM meta WHERE key = 'schema_version'`)?.value).toBe(
      // The head version, never a literal - a hardcoded number fails on every
      // future migration for a reason unrelated to what this test checks.
      String(SCHEMA_VERSION),
    )
    for (const table of ['backlog_items', 'backlog_events', 'learnings']) {
      expect(
        db.get(`SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?`, table),
      ).toBeTruthy()
    }
  })

  it('adds the recovery columns when upgrading from version 16', () => {
    const db = openDatabase(':memory:')
    db.exec(`ALTER TABLE milestones DROP COLUMN run_state`)
    db.exec(`ALTER TABLE loops DROP COLUMN last_activity_at`)
    db.run(`UPDATE meta SET value = '16' WHERE key = 'schema_version'`)

    migrate(db)

    expect(db.get<{ value: string }>(`SELECT value FROM meta WHERE key = 'schema_version'`)?.value).toBe(
      // The head version, never a literal - a hardcoded number fails on every
      // future migration for a reason unrelated to what this test checks.
      String(SCHEMA_VERSION),
    )
    expect(
      db.get(`SELECT name FROM pragma_table_info('milestones') WHERE name = 'run_state'`),
    ).toBeTruthy()
    expect(
      db.get(`SELECT name FROM pragma_table_info('loops') WHERE name = 'last_activity_at'`),
    ).toBeTruthy()
  })

  it('adds the hold tables when upgrading from version 12', () => {
    const db = openDatabase(':memory:')
    db.exec(`DROP TABLE hold_acks`)
    db.exec(`DROP TABLE hold_notifications`)
    db.run(`UPDATE meta SET value = '12' WHERE key = 'schema_version'`)

    migrate(db)

    expect(db.get<{ value: string }>(`SELECT value FROM meta WHERE key = 'schema_version'`)?.value).toBe(
      // The head version, never a literal - a hardcoded number fails on every
      // future migration for a reason unrelated to what this test checks.
      String(SCHEMA_VERSION),
    )
    for (const table of ['hold_acks', 'hold_notifications']) {
      expect(
        db.get(`SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?`, table),
      ).toBeTruthy()
    }
  })
})
