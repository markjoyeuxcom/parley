import { chmodSync, mkdirSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'

/**
 * The `parley` command a pane finds on its PATH.
 *
 * Every CLI in a pane has a shell and nothing else in common — Claude Code,
 * Codex and Agy share no tool protocol — so the capability is a script, which
 * all three can already run. Discovery is the shim being on PATH plus a line
 * in AGENTS.md, the same route that taught them to check `PARLEY_PANE`.
 *
 * `sh`, not `bash` or `node`: it has to run under whatever a CLI shells out
 * with. Text is piped to curl as a raw body rather than quoted into JSON,
 * because escaping a model's output — quotes, backticks, newlines — from a
 * shell script is a bug in waiting.
 */
export const SHIM = `#!/bin/sh
# Parley relay. Hands text to another pane in the same Parley window.
#
#   parley relay codex "have a look at this"
#   some-command | parley relay claude
#
# The text is pasted into that pane's prompt and NOT sent. A person there
# presses Enter. That is deliberate: nothing another model wrote should be
# able to run on its own.
set -eu

if [ "\${1:-}" != "relay" ]; then
  echo "usage: parley relay <pane> [text...]   (text may also come on stdin)" >&2
  exit 2
fi
if [ -z "\${PARLEY_RELAY_URL:-}" ]; then
  echo "not running inside a Parley pane" >&2
  exit 2
fi
target="\${2:-}"
if [ -z "$target" ]; then
  echo "name a pane, for example: parley relay codex \\"hello\\"" >&2
  exit 2
fi
shift 2

if [ "$#" -gt 0 ]; then
  printf '%s' "$*"
else
  cat
fi | curl -sS --fail-with-body -X POST \\
  -H "Authorization: Bearer \${PARLEY_RELAY_TOKEN:-}" \\
  -H "X-Parley-From: \${PARLEY_PANE_ID:-}" \\
  -H "Content-Type: text/plain" \\
  --data-binary @- \\
  "\${PARLEY_RELAY_URL}/relay?to=\${target}"
`

/** Writes the shim and returns the directory to put on a pane's PATH. */
export function installShim(userDataDir: string): string {
  const binDir = join(userDataDir, 'bin')
  mkdirSync(binDir, { recursive: true })
  const path = join(binDir, 'parley')
  writeFileSync(path, SHIM, 'utf8')
  // Rewritten and re-marked on every launch: a stale shim from an older build
  // would talk a protocol this one no longer serves.
  chmodSync(path, 0o755)
  return binDir
}
