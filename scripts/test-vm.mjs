#!/usr/bin/env node
// Runs the suite inside a local Tart macOS VM instead of on this desktop.
//
// The checks binary opens real Ghostty surfaces, menus and windows, which
// land on whoever's screen runs it and fail when a person touches the Mac or
// the display sleeps. A Tart VM has a display of its own, so the same suite
// runs there untouched, with the pins .github/workflows/ci.yml carries, and a
// green run here means what a green CI run means.
//
//   npm run test:vm                      # the pipeline's sequence
//   npm run test:vm -- run test:checks -- --only "pane menu"
//
// The VM is a persistent clone named parley-dev (PARLEY_TEST_VM overrides),
// created once with the pinned image:
//
//   tart clone <MACOS_IMAGE from .github/workflows/ci.yml> parley-dev
//
// Each run starts the VM headless if it is stopped, installs the pinned Node
// inside it once, replaces the guest's copy of the working tree (tracked and
// untracked files plus .git, piped through `tart exec -i` as one tar stream;
// ignored build caches in the guest are kept, so the second build is fast),
// then runs npm in the guest and exits with its status. Nothing is read back
// from the guest except its output. The guest agent in the Cirrus Labs images
// is what makes `tart exec` work; no SSH is set up.
import { spawn, spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

export const GUEST_REPO = "~/parley";
export const DEFAULT_VM = "parley-dev";
const BOOT_TIMEOUT_SECONDS = 240;

export const CI_WORKFLOW = ".github/workflows/ci.yml";

// The pins CI uses, read from the workflow's env block so there is one place
// to bump them. A missing pin is an error, never a default.
export function ciPins(yaml) {
  const pick = (key, pattern) => {
    const match = yaml.match(new RegExp(`^\\s*${key}:\\s*"?(${pattern})"?\\s*$`, "m"));
    if (!match) throw new Error(`${CI_WORKFLOW} has no ${key} pin`);
    return match[1];
  };
  return {
    image: pick("MACOS_IMAGE", "ghcr\\.io/[^\\s\"]+"),
    nodeVersion: pick("NODE_VERSION", "[0-9]+\\.[0-9]+\\.[0-9]+"),
    nodeSHA256: pick("NODE_SHA256", "[0-9a-f]{64}"),
    dockerOnlyChecks: pick("DOCKER_ONLY_CHECKS", "[^\"]+"),
  };
}

// The State of one local VM in `tart list --format json`, or null when it
// does not exist.
export function vmState(listingJSON, name) {
  const rows = JSON.parse(listingJSON);
  const row = rows.find((r) => r.Name === name && (r.Source ?? "local") === "local");
  return row ? row.State : null;
}

// One word for /bin/sh. Anything outside a conservative safe set is
// single-quoted, with embedded single quotes closed, escaped and reopened.
export function shellWord(word) {
  if (/^[A-Za-z0-9_./:=@%+,-]+$/.test(word)) return word;
  return `'${word.replace(/'/g, `'"'"'`)}'`;
}

const nodeDirectory = (pins) => `$HOME/node-v${pins.nodeVersion}-darwin-arm64`;
const guestPath = (pins) => `${nodeDirectory(pins)}/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin`;

// Installs the pinned nodejs.org build into the guest's home once, checked
// against the pinned digest, exactly as the pipeline's before_script does.
export function guestSetupScript(pins) {
  const dir = nodeDirectory(pins);
  const archive = `node-v${pins.nodeVersion}-darwin-arm64.tar.xz`;
  return [
    "set -eu",
    `dir="${dir}"`,
    `if [ -x "$dir/bin/node" ]; then exit 0; fi`,
    `tmp="$HOME/${archive}"`,
    `curl --fail --location --silent --show-error --output "$tmp" "https://nodejs.org/dist/v${pins.nodeVersion}/${archive}"`,
    `echo "${pins.nodeSHA256}  $tmp" | shasum -a 256 -c -`,
    `tar -xJf "$tmp" -C "$HOME"`,
    `rm -f "$tmp"`,
  ].join("\n");
}

// Replaces the guest's working tree with the tar stream on stdin. Files the
// previous copy tracked or had untracked are removed first, so a file
// deleted on the host disappears in the guest too, while ignored paths
// (native/.build, the Swift caches) stay for the next build. macOS xargs runs
// nothing on empty input.
export function guestSyncScript() {
  return [
    "set -eu",
    `mkdir -p ${GUEST_REPO}`,
    `cd ${GUEST_REPO}`,
    "if [ -d .git ]; then git ls-files -co --exclude-standard -z | xargs -0 rm -f; fi",
    "tar -x -f -",
  ].join("\n");
}

// Runs npm in the guest: the arguments given, or CI's own sequence (the two
// Docker-only checks skipped, since the VM has no daemon).
export function guestRunScript(pins, npmArguments) {
  const command = npmArguments.length > 0
    ? `exec npm ${npmArguments.map(shellWord).join(" ")}`
    : [
        `npm run test:checks -- --skip ${shellWord(pins.dockerOnlyChecks)}`,
        "npm run test:scripts",
        "npm run scan:public",
        "npm run scan:platform",
        "exec npm run build",
      ].join(" && ");
  return [
    "set -eu",
    `export PATH="${guestPath(pins)}"`,
    `cd ${GUEST_REPO}`,
    command,
  ].join("\n");
}

function run(command, args, options = {}) {
  const result = spawnSync(command, args, { stdio: ["ignore", "pipe", "pipe"], encoding: "utf8", ...options });
  if (result.error) throw result.error;
  return result;
}

function fail(message) {
  console.error(`test:vm: ${message}`);
  process.exit(1);
}

const sleep = (seconds) => new Promise((resolve) => setTimeout(resolve, seconds * 1000));

async function ensureRunning(vm, pins) {
  const listing = run("tart", ["list", "--format", "json"]);
  if (listing.status !== 0) fail(`tart list failed: ${listing.stderr.trim()}`);
  const state = vmState(listing.stdout, vm);
  if (state === null) {
    fail(`no VM named ${vm}. Create it once from the pipeline's image:\n\n  tart clone ${pins.image} ${vm}\n`);
  }
  if (state !== "running") {
    console.error(`test:vm: ${vm} is ${state}; starting it headless`);
    const child = spawn("tart", ["run", "--no-graphics", vm], { detached: true, stdio: "ignore" });
    child.unref();
  }
  const deadline = Date.now() + BOOT_TIMEOUT_SECONDS * 1000;
  while (Date.now() < deadline) {
    const probe = run("tart", ["exec", vm, "/usr/bin/true"]);
    if (probe.status === 0) return;
    await sleep(3);
  }
  fail(`${vm} did not answer tart exec within ${BOOT_TIMEOUT_SECONDS} seconds`);
}

function execInGuest(vm, script, { stdin = "ignore", tty = false } = {}) {
  const args = ["exec", ...(tty ? ["-t"] : []), ...(stdin !== "ignore" ? ["-i"] : []), vm, "/bin/sh", "-c", script];
  const result = spawnSync("tart", args, { stdio: [stdin, "inherit", "inherit"] });
  if (result.error) throw result.error;
  return result.status ?? 1;
}

function syncTree(root, vm) {
  // The host side is a fixed pipeline over two fixed commands; only the VM
  // name, checked above, and the guest script reach it, and the script goes
  // through one shellWord.
  const pipeline = `git ls-files -co --exclude-standard -z | tar -c -f - --null -T - .git | tart exec -i ${vm} /bin/sh -c ${shellWord(guestSyncScript())}`;
  const result = spawnSync("/bin/bash", ["-o", "pipefail", "-c", pipeline], { cwd: root, stdio: "inherit" });
  if (result.error) throw result.error;
  return result.status ?? 1;
}

async function main() {
  const root = dirname(dirname(fileURLToPath(import.meta.url)));
  const vm = process.env.PARLEY_TEST_VM || DEFAULT_VM;
  if (!/^[A-Za-z0-9_.-]+$/.test(vm)) fail(`PARLEY_TEST_VM must be a plain VM name, not ${JSON.stringify(vm)}`);
  const pins = ciPins(readFileSync(join(root, CI_WORKFLOW), "utf8"));
  const npmArguments = process.argv.slice(2);

  await ensureRunning(vm, pins);

  console.error("test:vm: preparing the guest toolchain");
  if (execInGuest(vm, guestSetupScript(pins)) !== 0) fail("guest toolchain setup failed");

  console.error(`test:vm: syncing the working tree to ${vm}:${GUEST_REPO}`);
  if (syncTree(root, vm) !== 0) fail("syncing the working tree failed");

  console.error(`test:vm: running ${npmArguments.length > 0 ? `npm ${npmArguments.join(" ")}` : "the pipeline sequence"} in ${vm}`);
  process.exit(execInGuest(vm, guestRunScript(pins, npmArguments), { tty: process.stdout.isTTY === true }));
}

if (import.meta.url === `file://${process.argv[1]}`) {
  main().catch((error) => fail(error.message));
}
