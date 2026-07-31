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
    const probe = cp.spawnSync(process.execPath, [file], {
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
      fs.symlinkSync(path.join(target, "parley-remote.mjs"), temporary);
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
