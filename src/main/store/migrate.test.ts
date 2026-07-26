import { describe, expect, it } from 'vitest'
import { migrate, openDatabase } from './db'

describe('schema 9 migration', () => {
  it('upgrades a populated version-8 database with its rows intact', () => {
    const db = openDatabase(':memory:')
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
      '9',
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
})
