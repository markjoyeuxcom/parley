import { randomUUID } from 'node:crypto'

/**
 * Identifiers, as a dependency leaf.
 *
 * Main-side rather than shared, because it reaches for node:crypto and
 * `shared/` is typechecked for the renderer too. The leaf-ness is the point,
 * not the folder.
 *
 * Separated from the store for the same reason `usage.ts` is separated from
 * the domain schemas: minting an id is a one-line runtime value, and importing
 * it used to drag in the whole persistence layer — and through it, the schema
 * library — for code that never touches a database. The remote execution
 * bundle must contain Parley's own code, Node built-ins, and nothing else.
 *
 * This file must never import the store, the domain schemas, or anything that
 * can reach node_modules. `repo.ts` re-exports it so existing callers are
 * unaffected, and there is still one definition.
 */

/** An opaque identifier. Kept as a plain string here; the schema validates it. */
export type Id = string

export function newId(): Id {
  return randomUUID()
}
