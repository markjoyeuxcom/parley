/**
 * The shell-syntax rule.
 *
 * Lives in shared because two places must agree on it: the harness, which
 * refuses to spawn such a command, and the UI, which should tell you *before*
 * you approve rather than after a thirty-minute run has gone unverified.
 */

/** Metacharacters that mean the command needs a shell we will not give it. */
const SHELL_METACHARS = /[|&;<>$`(){}[\]*?~\n\r]/

export function isShellFree(line: string): boolean {
  return !SHELL_METACHARS.test(line)
}

/** The offending characters, for an error message worth reading. */
export function shellMetacharsIn(line: string): string[] {
  return [...new Set(line.match(new RegExp(SHELL_METACHARS, 'g')) ?? [])]
}
