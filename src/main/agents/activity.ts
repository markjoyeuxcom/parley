/**
 * Formatting for the live activity feed.
 *
 * These lines are read at a glance while a run is in flight, so the useful part
 * has to be at the front. Both CLIs report commands verbatim, which means almost
 * every line arrives wrapped in an identical `/bin/zsh -lc "…"` prefix that
 * tells the reader nothing and consumes the width before the real command
 * starts.
 */

const SHELL_WRAPPER = /^(?:[\w./-]*\/)?(?:sh|bash|zsh|dash|ksh|fish)\s+-[a-zA-Z]*c\s+([\s\S]*)$/

/** Unwraps a shell invocation to the command it actually runs. */
export function unwrapShell(raw: string): string {
  const flat = raw.replace(/\s+/g, ' ').trim()
  const match = SHELL_WRAPPER.exec(flat)
  if (!match?.[1]) return flat

  let inner = match[1].trim()
  const quote = inner[0]
  if ((quote === '"' || quote === "'") && inner.length > 1 && inner.endsWith(quote)) {
    inner = inner.slice(1, -1).trim()
  }
  return inner || flat
}

/**
 * Truncates on a word boundary where one is close enough to the limit.
 *
 * Cutting mid-token produces lines like `rg --files | so` that read as though
 * the command itself were malformed.
 */
export function truncateCommand(text: string, max = 160): string {
  if (text.length <= max) return text
  const slice = text.slice(0, max)
  const boundary = slice.lastIndexOf(' ')
  const cut = boundary > max * 0.6 ? slice.slice(0, boundary) : slice
  return `${cut.trimEnd()}…`
}

/** Full formatting for a command reported by an agent. */
export function describeCommand(raw: string): string {
  return truncateCommand(unwrapShell(raw))
}
