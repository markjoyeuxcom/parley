import { existsSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'
import { DatabaseSync } from 'node:sqlite'
import { NodeSqliteDb, SCHEMA_VERSION, type Db } from '@main/store/db'

/**
 * Opening the app's record from outside the app.
 *
 * The one thing this must never do is change it. `openDatabase` creates the
 * schema and migrates forward, which is exactly right for the process that
 * OWNS the record and exactly wrong for a reader: a CLI built from a
 * different checkout would quietly migrate the database of the app someone
 * has running, and a CLI pointed at a path that does not exist would create
 * an empty one and truthfully report that there is nothing in it.
 *
 * Both failures are silent, and both produce confident wrong answers. So:
 * refuse a missing file, refuse a version that is not exactly ours, and never
 * write.
 */

/**
 * Where the app keeps its record, per platform and per channel.
 *
 * Dev and packaged deliberately do not share one — the checkout migrates
 * ahead of any frozen build — so a reader has to be told which it wants, and
 * guessing wrong means answering questions about the wrong work.
 */
export function defaultRecordPath(dev: boolean, platform = process.platform): string {
  const name = dev ? 'parley-dev' : 'Parley'
  if (platform === 'darwin') return join(homedir(), 'Library', 'Application Support', name, 'parley.db')
  if (platform === 'win32') {
    return join(process.env['APPDATA'] ?? join(homedir(), 'AppData', 'Roaming'), name, 'parley.db')
  }
  return join(process.env['XDG_CONFIG_HOME'] ?? join(homedir(), '.config'), name, 'parley.db')
}

export class RecordError extends Error {}

export function openRecordForReading(path: string): Db {
  if (!existsSync(path)) {
    // Not "no plans found". An empty answer and a missing record are
    // different facts, and only one of them is about the work.
    throw new RecordError(
      `no Parley record at ${path}. Point --db at one, or pass --dev for a development checkout's record.`,
    )
  }

  const handle = new DatabaseSync(path, { readOnly: true })
  const db = new NodeSqliteDb(handle)
  const row = db.get<{ value: string }>(`SELECT value FROM meta WHERE key = 'schema_version'`)
  const found = row ? Number(row.value) : 0
  if (found !== SCHEMA_VERSION) {
    // Both directions refuse, and for the same reason: this build's queries
    // name columns that a different schema may not have. Migrating to fix it
    // is the owner's job, not a reader's — doing it here would rewrite the
    // record of a running app to suit a command someone typed.
    throw new RecordError(
      found === 0
        ? `${path} is not a Parley record`
        : `${path} is schema v${found} and this build reads v${SCHEMA_VERSION}. ` +
          `Open it in the matching Parley — a reader will not migrate a record it does not own.`,
    )
  }
  return db
}
