import { createHash } from 'node:crypto'

/**
 * The install-time bootstrap.
 *
 * Getting the bundle onto a host takes three steps after the bytes land, and
 * every one of them needs to name the file that was just uploaded: hash it,
 * run its handshake, then activate it. Naming a path on an ssh command line is
 * exactly what the whole protocol exists to avoid — OpenSSH joins the remote
 * command's arguments with spaces and hands the string to the remote login
 * shell — so SFTP alone does not close the hole. It only moves it three steps
 * further down the corridor.
 *
 * The answer is the same one the runner uses: a FIXED remote command, with
 * everything that varies arriving as JSON on stdin. The command is
 * `node -e <constant program>`, and the program below is that constant. It is
 * base64-encoded before it goes near a shell so that its own punctuation
 * cannot be reinterpreted, and so a future edit that happens to add an
 * apostrophe cannot silently break quoting.
 *
 * It is deliberately not a second runner. Three operations, no generic argv
 * execution, no arbitrary filesystem access, no environment forwarding. The
 * moment it grows the ability to run what it is told, it becomes the remote
 * shell we refused to have.
 */

/** Where an installation lives, relative to the remote home directory. */
export const INSTALL_ROOT = '.local/lib/parley/remote'
export const BIN_DIR = '.local/bin'
export const LINK_NAME = 'parley-remote'

/**
 * Paths a request may name.
 *
 * Deliberately boring: no spaces, no `~`, no backslashes, no control
 * characters, nothing that a path parser anywhere in the chain could read as
 * structure. SFTP carries a pathname as transfer data rather than as shell
 * text, but the bootstrap still resolves and compares these, and a grammar
 * this dull removes a whole class of argument about what they might mean.
 */
export const BORING_PATH = /^[A-Za-z0-9._/-]+$/

export function isBoringPath(path: string): boolean {
  if (!BORING_PATH.test(path)) return false
  // Relative to home, always: an absolute path or a traversal would let a
  // request reach outside the installation root, which is the one thing this
  // grammar is not able to express on its own.
  if (path.startsWith('/')) return false
  return !path.split('/').includes('..')
}

/**
 * The program, as source.
 *
 * Kept as text rather than as a compiled module on purpose. It has to survive
 * as one constant string that never varies by run, and building it separately
 * would mean the app's runtime depended on a second build step having happened
 * — a way for a host to be handed a bootstrap from a different version than
 * the Parley that is talking to it.
 *
 * It reads one JSON request on stdin and answers on stdout with one JSON line.
 * Its own diagnostics go to stderr, which is where an unusable bootstrap
 * belongs: before it answers, there is no protocol to speak.
 */
export const BOOTSTRAP_SOURCE = `
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const crypto = require("node:crypto");
const cp = require("node:child_process");

const HOME = process.env.HOME || os.homedir();
const ROOT = path.join(HOME, "${INSTALL_ROOT}");
const BIN = path.join(HOME, "${BIN_DIR}");
const LINK = path.join(BIN, "${LINK_NAME}");
const BORING = /^[A-Za-z0-9._\\/-]+$/;

function fail(message) {
  process.stdout.write(JSON.stringify({ ok: false, error: message }) + "\\n");
  process.exit(1);
}

function resolveInside(relative) {
  if (typeof relative !== "string" || !BORING.test(relative)) fail("path is not allowed");
  if (relative.startsWith("/") || relative.split("/").indexOf("..") >= 0) fail("path escapes home");
  const full = path.resolve(HOME, relative);
  // Both sides are resolved through realpath before comparing. Comparing a
  // resolved child against an unresolved root is the classic way to get this
  // wrong: any symlink anywhere above the install directory — /var to
  // /private/var on macOS, a home directory on a mounted volume — makes every
  // legitimate path look like an escape.
  let root = ROOT;
  try { root = fs.realpathSync(ROOT); } catch (e) {}
  let real = full;
  try { real = fs.realpathSync(path.dirname(full)); } catch (e) { fail("path does not exist"); }
  if (real !== root && real.indexOf(root + path.sep) !== 0) fail("path is outside the install root");
  return path.join(real, path.basename(full));
}

/**
 * The launcher: an executable that names its own interpreter.
 *
 * The bundle ships with a "#!/usr/bin/env node" shebang, which is useless on
 * exactly the hosts this bootstrap exists to support — nvm, asdf and mise put
 * node somewhere no non-interactive shell will look, so "env node" fails with
 * 127. And sftp does not carry a mode, so the uploaded file arrives 644 and
 * cannot be executed at all. Two separate reasons a run fails at the same
 * point.
 *
 * A tiny sh script solves both, and can only be written here: this process IS
 * the node the target configured, so process.execPath is the right interpreter
 * by construction rather than by guesswork.
 *
 * The launcher is not hashed, because there is nothing to hash it against —
 * unlike the bundle, it is written by the host from its own execPath rather
 * than uploaded. What matters is that the BUNDLE is never rewritten: the bytes
 * that were verified stay byte-for-byte the bytes that run.
 */
function writeLauncher(bundle) {
  const node = process.execPath;
  if (!BORING.test(node)) fail("the host's node path is not a boring path: " + node);
  if (!BORING.test(bundle)) fail("the bundle path is not a boring path");
  const at = path.join(path.dirname(bundle), "${LINK_NAME}");
  const script = [
    "#!/bin/sh",
    "# Written by Parley's bootstrap. The interpreter is named absolutely: a",
    "# host managed by nvm, asdf or mise has no node on its non-interactive PATH.",
    "exec '" + node + "' '" + bundle + "' " + '"$@"',
    "",
  ].join("\\n");
  fs.writeFileSync(at, script, { mode: 0o755 });
  // writeFileSync's mode only applies when it creates the file, and staging is
  // fresh per nonce so it always does — but the executable bit is the whole
  // point of this file, so it is not left to that.
  fs.chmodSync(at, 0o755);
  return at;
}

function lock() {
  fs.mkdirSync(ROOT, { recursive: true });
  const at = path.join(ROOT, ".lock");
  for (let i = 0; i < 50; i++) {
    try { return fs.openSync(at, "wx"); } catch (e) {
      try {
        const age = Date.now() - fs.statSync(at).mtimeMs;
        if (age > 120000) { fs.unlinkSync(at); continue; }
      } catch (e2) { continue; }
      const wait = new Int32Array(new SharedArrayBuffer(4));
      Atomics.wait(wait, 0, 0, 100);
    }
  }
  fail("another install is in progress");
}

function unlock(fd) {
  try { fs.closeSync(fd); } catch (e) {}
  try { fs.unlinkSync(path.join(ROOT, ".lock")); } catch (e) {}
}

function readRequest(done) {
  let input = "";
  process.stdin.setEncoding("utf8");
  process.stdin.on("data", function (c) { input += c; });
  process.stdin.on("end", function () {
    try { done(JSON.parse(input)); } catch (e) { fail("expected one JSON request on stdin"); }
  });
}

readRequest(function (request) {
  const op = request && request.operation;

  if (op === "verify-and-handshake") {
    const file = resolveInside(request.relativePath);
    let bytes;
    try { bytes = fs.readFileSync(file); } catch (e) { fail("uploaded bundle is missing"); }
    const actual = crypto.createHash("sha256").update(bytes).digest("hex");
    if (actual !== request.expectedHash) {
      fail("uploaded bundle hash " + actual + " does not match " + request.expectedHash);
    }
    // Probed THROUGH the launcher, not as an argument to node.
    //
    // "node <bundle>" would prove something a run never does, and it is worth
    // being blunt about how that failed: it passed on a host where every run
    // then died, because passing an argument to node bypasses both the
    // executable bit and the shebang — the only two things that were broken.
    // The gate that promises a bundle which cannot run never becomes the one
    // that runs has to exercise the mechanism a run exercises.
    const launcher = writeLauncher(file);
    const probe = cp.spawnSync(launcher, [], {
      input: JSON.stringify({ version: request.protocolVersion, operation: "handshake", runId: "install" }) + "\\n",
      encoding: "utf8",
      timeout: 60000,
    });
    process.stdout.write(JSON.stringify({
      ok: true, hash: actual, node: process.execPath, nodeVersion: process.version,
      handshake: probe.stdout || "", handshakeStderr: (probe.stderr || "").slice(0, 2000),
      status: probe.status,
    }) + "\\n");
    return;
  }

  if (op === "activate") {
    if (typeof request.buildId !== "string" || !/^[a-f0-9]{64}$/.test(request.buildId)) {
      fail("build id must be a sha256");
    }
    const staged = resolveInside(request.relativePath);
    const fd = lock();
    try {
      const target = path.join(ROOT, request.buildId);
      if (fs.existsSync(target)) fs.rmSync(target, { recursive: true, force: true });
      // Same filesystem by construction — the staging directory is a sibling
      // of the target inside ROOT, so this rename is atomic. Staging under
      // /tmp would cross a filesystem and silently stop being one.
      fs.renameSync(path.dirname(staged), target);
      fs.mkdirSync(BIN, { recursive: true });
      let previous = null;
      try { previous = fs.readlinkSync(LINK); } catch (e) {}
      const temporary = path.join(BIN, ".${LINK_NAME}-" + request.buildId.slice(0, 8));
      try { fs.unlinkSync(temporary); } catch (e) {}
      // Written a second time, now that the bundle has its final path.
      //
      // The staging launcher named a path inside .install-<nonce>, which is
      // the directory this rename just made vanish — so it was correct for
      // the probe and dangling from the instant it was activated. Rewriting
      // it here is what makes the verified-then-activated order safe for a
      // file that has to name where it lives. Rewriting the BUNDLE would
      // break the hash guarantee; the launcher is host-authored and carries
      // none.
      writeLauncher(path.join(target, "parley-remote.mjs"));
      // Linking the .mjs instead would put the shebang back on the critical
      // path, which is one of the two reasons a run could not start at all.
      fs.symlinkSync(path.join(target, "${LINK_NAME}"), temporary);
      fs.renameSync(temporary, LINK);
      if (previous) fs.writeFileSync(path.join(ROOT, ".previous"), previous, "utf8");
      process.stdout.write(JSON.stringify({ ok: true, active: LINK, previous: previous }) + "\\n");
    } finally { unlock(fd); }
    return;
  }

  if (op === "rollback") {
    const fd = lock();
    try {
      let previous = null;
      try { previous = fs.readFileSync(path.join(ROOT, ".previous"), "utf8").trim(); } catch (e) {}
      if (!previous || !fs.existsSync(previous)) fail("no previous build to roll back to");
      const temporary = path.join(BIN, ".${LINK_NAME}-rollback");
      try { fs.unlinkSync(temporary); } catch (e) {}
      fs.symlinkSync(previous, temporary);
      fs.renameSync(temporary, LINK);
      process.stdout.write(JSON.stringify({ ok: true, active: LINK, restored: previous }) + "\\n");
    } finally { unlock(fd); }
    return;
  }

  fail("unknown operation");
});
`

/**
 * The argv element carrying the program.
 *
 * Base64 first, then a single-quoted wrapper. The encoding is not decoration:
 * the remote login shell WILL parse this token, and base64's alphabet contains
 * nothing it can act on. Quoting a raw JavaScript program would work until
 * somebody wrote an apostrophe in a comment.
 */
export function bootstrapArgument(): string {
  const encoded = Buffer.from(BOOTSTRAP_SOURCE, 'utf8').toString('base64')
  return `'eval(Buffer.from("${encoded}","base64").toString())'`
}

/** What Parley believes it is asking the host to run, for the record. */
export function bootstrapDigest(): string {
  return createHash('sha256').update(BOOTSTRAP_SOURCE).digest('hex').slice(0, 12)
}
