#!/usr/bin/env node
// Guards ParleyCore's platform surface.
//
// ParleyCore's file-level dependency on Apple frameworks is concentrated in a
// known set. This scan records that set exactly and fails when it changes, so
// the rest cannot quietly acquire one between releases.
//
// Read the number it prints as a maintenance fact, not portability progress.
// A file carrying no platform import may still depend on a Darwin-bound service,
// and useful separation work can leave the count untouched: lifting a domain
// type out of a platform-importing file is real progress the count cannot see.
// Portability is established by compiling a dependency-complete slice, not here.
//
// It is a ratchet, not a snapshot. Adding a platform import to a new file fails.
// Removing one from a listed file also fails, because the baseline below must
// then be tightened rather than left stale and permissive.
//
// This deliberately guards imports, not APIs. A Linux build additionally needs
// the syscall guarantees behind those imports re-derived (LOCAL_PEERPID,
// O_EXLOCK, O_EVTONLY, renamex_np, POSIX_SPAWN_CLOEXEC_DEFAULT, SO_NOSIGPIPE,
// proc_pidinfo, KERN_PROCARGS2). See docs/headless-and-portability-feasibility.md.

import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";

export const GUARDED_FRAMEWORKS = [
  "Darwin", "CryptoKit", "Security", "ImageIO", "CoreGraphics", "AppKit", "SwiftUI", "UIKit",
];

// Every ParleyCore file permitted to carry a platform import, and which.
// Shrink this as seams move syscalls behind protocols. Never extend it without
// deciding that the file genuinely belongs on the platform side of the seam.
export const BASELINE = {
  "AgentContextReviews.swift": ["Darwin"],
  "ApprovedCommandProcess.swift": ["Darwin"],
  "ApprovedCommandWorker.swift": ["CryptoKit", "Darwin"],
  "AttentionProjection.swift": ["Darwin"],
  "CodexHostConfiguration.swift": ["Darwin"],
  "CollaborationHistoryRetention.swift": ["Darwin"],
  "CommandRunner.swift": ["Darwin"],
  "ContainerGitAccess.swift": ["Darwin"],
  "ContainerPaneService.swift": ["Darwin"],
  "ContextPacks.swift": ["CryptoKit", "Darwin", "ImageIO"],
  "CoreService.swift": ["Darwin", "Security"],
  "Diagnostics.swift": ["Darwin"],
  "ExternalWorkspaceOpen.swift": ["Darwin"],
  "GhosttyAppearanceImport.swift": ["Darwin"],
  "GhosttyLaunchPreflight.swift": ["Darwin"],
  "HandoffRecipes.swift": ["Darwin"],
  "PaneProcessAnchor.swift": ["Darwin"],
  "ParleyRuntime.swift": ["Darwin"],
  "PermissionProfiles.swift": ["Darwin"],
  "Relay.swift": ["Darwin", "Security"],
  "RelayActivityJournal.swift": ["Darwin"],
  "RelayFileTransport.swift": ["Darwin"],
  "RelayHTTPServer.swift": ["Darwin"],
  "RelayTicketServer.swift": ["Darwin"],
  "RelayHandoffJournal.swift": ["Darwin"],
  "ReleaseLifecycle.swift": ["CryptoKit"],
  "ReviewedBusyDrafts.swift": ["Darwin"],
  "ReviewedCommandRunCoordinator.swift": ["CryptoKit"],
  "TaskManager.swift": ["Darwin"],
  "WorkbenchWindowGeometry.swift": ["CoreGraphics"],
  "WorkspaceLayouts.swift": ["Darwin"],
  "WorkspaceRegistry.swift": ["Darwin"],
};

export function scanSource(source) {
  return GUARDED_FRAMEWORKS.filter((name) =>
    new RegExp(`^import ${name}\\s*$`, "m").test(source)
  ).sort();
}

export function scanDirectory(directory, read = readFileSync, list = readdirSync) {
  const found = {};
  for (const file of list(directory).filter((f) => f.endsWith(".swift")).sort()) {
    const imports = scanSource(read(join(directory, file), "utf8"));
    if (imports.length > 0) found[file] = imports;
  }
  return found;
}

export function compare(found, baseline = BASELINE) {
  const problems = [];
  const same = (a, b) => a.length === b.length && a.every((v, i) => v === b[i]);
  for (const [file, imports] of Object.entries(found)) {
    const allowed = baseline[file];
    if (!allowed) {
      problems.push(`${file} gained a platform import (${imports.join(", ")}) and is not in the baseline.`);
    } else if (!same(imports, [...allowed].sort())) {
      problems.push(`${file} now imports ${imports.join(", ")}; the baseline records ${[...allowed].sort().join(", ")}.`);
    }
  }
  for (const file of Object.keys(baseline)) {
    if (!found[file]) {
      problems.push(`${file} no longer carries a platform import. Remove it from the baseline so the guard tightens.`);
    }
  }
  return problems;
}

function main() {
  const directory = "native/Sources/ParleyCore";
  const found = scanDirectory(directory);
  const problems = compare(found);
  const total = readdirSync(directory).filter((f) => f.endsWith(".swift")).length;
  if (problems.length > 0) {
    console.error("Platform dependency scan failed:\n");
    for (const problem of problems) console.error(`  - ${problem}`);
    console.error(`\n${Object.keys(BASELINE).length} of ${total} ParleyCore files may carry a platform import.`);
    console.error("Update scripts/platform-dependency-scan.mjs only as a deliberate decision.");
    process.exit(1);
  }
  const pure = total - Object.keys(found).length;
  console.log(`Platform dependency scan passed: ${pure} of ${total} ParleyCore files carry no platform import.`);
}

if (import.meta.url === `file://${process.argv[1]}`) main();
