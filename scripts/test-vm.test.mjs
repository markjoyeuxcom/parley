import { strict as assert } from "node:assert";
import test from "node:test";
import {
  ciPins,
  vmState,
  guestSetupScript,
  guestSyncScript,
  guestRunScript,
  shellWord,
  isPrimaryCheckout,
  archiveEntries,
  lockDirectory,
  GUEST_REPO,
} from "./test-vm.mjs";

const CI = `
variables:
  GIT_DEPTH: 0
  MACOS_IMAGE: ghcr.io/cirruslabs/macos-tahoe-base@sha256:1b09abc
  NODE_VERSION: "24.21.0"
  NODE_SHA256: "6239d4cf92d864487ec8cd3615038f7b67e7f58b77b21cd2f09ea9fbd68065fe"
  DOCKER_ONLY_CHECKS: "container bypass preflight,container follow-up image probe"
`;

test("ciPins reads the image and Node pins from the CI workflow's env block", () => {
  assert.deepEqual(ciPins(CI), {
    image: "ghcr.io/cirruslabs/macos-tahoe-base@sha256:1b09abc",
    nodeVersion: "24.21.0",
    nodeSHA256: "6239d4cf92d864487ec8cd3615038f7b67e7f58b77b21cd2f09ea9fbd68065fe",
    dockerOnlyChecks: "container bypass preflight,container follow-up image probe",
  });
});

test("ciPins refuses a file missing a pin rather than guessing", () => {
  assert.throws(() => ciPins("variables:\n  NODE_VERSION: \"1.0.0\"\n"), /MACOS_IMAGE/);
});

test("vmState reads one VM out of tart list --format json", () => {
  const listing = JSON.stringify([
    { Source: "local", Name: "other", Disk: 50, Size: 20, State: "running" },
    { Source: "local", Name: "parley-dev", Disk: 50, Size: 31, State: "stopped" },
  ]);
  assert.equal(vmState(listing, "parley-dev"), "stopped");
  assert.equal(vmState(listing, "other"), "running");
  assert.equal(vmState(listing, "missing"), null);
});

test("shellWord quotes anything the shell could interpret", () => {
  assert.equal(shellWord("plain"), "plain");
  assert.equal(shellWord("has space"), "'has space'");
  assert.equal(shellWord("it's"), `'it'"'"'s'`);
  assert.equal(shellWord("$HOME;rm"), "'$HOME;rm'");
});

test("guest setup installs the pinned Node once and checks its digest", () => {
  const script = guestSetupScript(ciPins(CI));
  assert.match(script, /node-v24\.21\.0-darwin-arm64/);
  assert.match(script, /6239d4cf92d864487ec8cd3615038f7b67e7f58b77b21cd2f09ea9fbd68065fe {2}/);
  assert.match(script, /shasum -a 256 -c/);
  assert.match(script, /set -eu/);
  // Already installed means no download at all.
  assert.match(script, /if \[ -x ".*\/bin\/node" \]/);
});

test("guest sync removes the previous tree's files and its whole .git but keeps ignored build caches", () => {
  const script = guestSyncScript();
  assert.match(script, new RegExp(`mkdir -p ${GUEST_REPO}`));
  assert.match(script, /git ls-files -co --exclude-standard -z \| xargs -0 rm -f/);
  // The previous .git goes whole, so a ref deleted on the host does not
  // survive in the guest (scan:public walks every ref). Nothing else is
  // removed recursively: native/.build must stay.
  assert.deepEqual(script.match(/rm -rf \S+/g), ["rm -rf .git"]);
  assert.ok(script.indexOf("rm -rf .git") < script.indexOf("tar -x"));
  assert.match(script, /tar -x/);
});

test("only the primary checkout is synced: a linked worktree's .git is a pointer into the host repository", () => {
  assert.equal(isPrimaryCheckout(".git\n"), true);
  assert.equal(isPrimaryCheckout("/Users/me/parley/.git/worktrees/feature\n"), false);
  assert.equal(isPrimaryCheckout(".git/worktrees/feature"), false);
});

test("archive entries leave out a tracked file deleted but not yet staged", () => {
  const present = new Set(["README.md", "scripts/test-vm.mjs"]);
  const listed = ["README.md", "deleted-but-unstaged.md", "scripts/test-vm.mjs", ""];
  assert.deepEqual(archiveEntries(listed, (entry) => present.has(entry)), ["README.md", "scripts/test-vm.mjs"]);
});

test("one run per VM is held by a lock directory named for the VM", () => {
  assert.equal(lockDirectory("parley-dev", "/tmp"), "/tmp/parley-test-vm-parley-dev.lock");
  assert.notEqual(lockDirectory("parley-dev", "/tmp"), lockDirectory("other", "/tmp"));
});

test("guest run uses the pinned Node, the synced tree and quoted arguments", () => {
  const script = guestRunScript(ciPins(CI), ["run", "test:checks", "--", "--only", "pane menu"]);
  assert.match(script, /node-v24\.21\.0-darwin-arm64\/bin/);
  assert.match(script, new RegExp(`cd ${GUEST_REPO}`));
  assert.match(script, /exec npm run test:checks -- --only 'pane menu'$/);
});

test("guest run defaults to the pipeline's sequence with the Docker-only checks skipped", () => {
  const script = guestRunScript(ciPins(CI), []);
  assert.match(script, /npm run test:checks -- --skip 'container bypass preflight,container follow-up image probe' && npm run test:scripts && npm run scan:public && npm run scan:platform && exec npm run build$/);
});

test("ciPins carries the Docker-only check names the pipeline skips", () => {
  assert.equal(ciPins(CI).dockerOnlyChecks, "container bypass preflight,container follow-up image probe");
});
