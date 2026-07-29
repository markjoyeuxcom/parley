export interface RelaunchApp {
  relaunch(options: { args: string[] }): void
  quit(): void
  exit(exitCode?: number): void
}

export const FRESH_BUILD_FLAG = '--parley-fresh-build'

export function applyFreshBuildFlag(
  argv: string[],
  env: Record<string, string | undefined>,
): boolean {
  const freshBuild = argv.includes(FRESH_BUILD_FLAG)
  if (freshBuild) delete env['ELECTRON_RENDERER_URL']
  return freshBuild
}

export function relaunchIntoFreshBuild(app: RelaunchApp, argv: string[]): void {
  // Deduped before appending, so repeated self-relaunches never accumulate
  // the flag. The next process sees it and drops ELECTRON_RENDERER_URL —
  // that is what makes it load the freshly built out/ instead of the dev
  // server the current process inherited.
  const args = argv.slice(1).filter((arg) => arg !== FRESH_BUILD_FLAG)
  args.push(FRESH_BUILD_FLAG)
  app.relaunch({ args })
  // quit, NEVER exit: before-quit is what disposes agent CLIs and ptys,
  // and app.exit skips it — orphaning paid runs that keep spending quota
  // headless. Nothing in this app vetoes quit.
  app.quit()
}
