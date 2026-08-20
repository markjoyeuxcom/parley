/**
 * Which URLs may be handed to the operating system.
 *
 * `shell.openExternal` asks macOS to open a URL with whatever is registered
 * for its scheme. Unfiltered that includes `file://`, `smb://` and every
 * custom scheme any installed app has claimed — the standard Electron
 * hardening miss, and one both audits flagged.
 *
 * There is no reachable trigger today: the renderer never calls `window.open`
 * or assigns `location`, the markdown parser emits a data tree rather than
 * HTML and parses no links, and no xterm link addon is installed. So this is
 * defence in depth against a renderer compromise, and against the link surface
 * growing later — which it will, because a transcript full of file paths and
 * URLs is an obvious thing to want to click.
 */

/** Schemes worth opening. Deliberately short. */
const ALLOWED = new Set(['http:', 'https:', 'mailto:'])

export function isOpenableExternally(candidate: string): boolean {
  let url: URL
  try {
    url = new URL(candidate)
  } catch {
    // Not a URL at all — a bare path, or something a caller built wrongly.
    return false
  }
  return ALLOWED.has(url.protocol)
}
