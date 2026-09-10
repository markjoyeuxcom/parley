# Vendor-managed host permissions: validation

Recorded 10 September 2026 for `feat/vendor-managed-host-permissions`.
The change removes Parley's outer Seatbelt wrapper from host vendor launches;
containers retain their reviewed mounts and the host Docker-client wrapper.
Vendor approvals remain enabled. The canonical protocol advances to 32.

## Automated results

Commands ran from the feature checkout through a native reviewed Shell when
host permissions were needed. Node denotes the installed mise-managed Node.
The validation runner invoked the build and test scripts below directly, with
the same arguments as `npm run build` and `npm test`.

| Command | Observed result |
| --- | --- |
| `node scripts/run-native-swift.mjs build --package-path native` | Passed. |
| `node scripts/run-native-swift.mjs run --package-path native parley-native-checks` | All 324 checks passed, including real Ghostty checks. |
| `node --test scripts/run-native-swift.test.mjs scripts/github-security.test.mjs scripts/native-macos-package.test.mjs scripts/native-macos-release.test.mjs scripts/public-repository-scan.test.mjs` | 41 passed; no failures or skips. |
| `node scripts/public-repository-scan.mjs` | Passed for publishable files and complete reachable Git history. |
| `native/.build/debug/parley-native-checks --only 'core control survives'` | Passed five consecutive executions with normal child-process signal handling. |
| `native/.build/debug/parley-native-checks --host-vendor-spike /Users/markjoyeux/.local/bin/codex` | All three probe groups passed using the installed local binary and disposable `CODEX_HOME`. No account or model calls. |
| `node scripts/run-native-swift.mjs run --package-path native parley-native-soak --rounds 25 --output dist/host-permissions-soak.json` | Passed: eight panes, 25 rounds, 200 delivered inputs, eight hidden-pane inputs, shell PID/TTY evidence and all test processes terminated. |

The real Codex probe covers ordinary sandbox startup, private-file read/write
refusal, own-endpoint read/write, project writes, patching, read-only refusal,
inherited `.git` protection and refusal of legacy configuration that replaces
the native permission profile. The native suite checks every vendor's fresh
and supported resume launch projection, credentials and generation rotation.

The first security regressions failed before implementation: a saved file
restored automatic execution authority, changed worker-ticket bytes were
accepted, a mutable locator redirected the native client and host launches
still carried the outer wrapper. They now pass. A separate-process request
with the correct synthetic control token is refused. Native control clients
still reattach and complete the existing consultation and history operations.

Repeated socket tests exposed SIGPIPE after a peer closed early. Both send
loops now suppress it per call; the repeated test then passed five times.
This matters because the reviewed worker's inherited signal disposition could
otherwise hide the failure in a single test run.

## Remaining manual acceptance

No new app was installed or launched, and no existing vendor pane was restarted.
Fresh and resumed interactive vendor sessions, their permission prompts and
live instruction uptake still need checking in the new app build. Launch
projection checks and the real Codex sandbox probe do not establish those facts.
The other vendors' native permission arguments are preserved, not newly verified
against signed-in sessions. No release, signing or notarization was performed.

The preflight is a point-in-time check, including at host-team approval. Vendor
configuration can change later. Native Codex rules cover sandboxed tools, not
the vendor parent or approved unsandboxed execution. Host agents remain trusted
same-user applications; native authority protection does not defend against
app-memory injection or a compromised account.

Detailed logs and the standalone soak JSON remain under the checkout's ignored
`dist/` directory. The validation logs completed successfully, but the original
Parley validation receipt became unavailable after the interrupted tool session;
the subsequent soak returned a captured exit status of zero without truncation.

## Integration with the core audit

GitLab main includes the core audit as `e71eb26`, merged by `e24c086`. The
host-permissions branch incorporates that main revision. The sole textual
conflict was the audit's `O_CLOEXEC` addition in the retired disk control-token
loader. The resolution keeps the memory-only token generator; no such lock or
file remains to inherit. The relay credential and inbox-watcher close-on-exec
changes remain.

The socket descriptor cleanup and interrupted-read retry coexist with peer-PID
authentication and per-send SIGPIPE suppression. The worker's bounded display
retry, Ctrl+C return to Shell and cancel-file race fix coexist with approval
digests. Context-review interruption, context-process cleanup and canonical
team-folder joining are retained, including both audit regression checks.

The integrated tree passed build, all 326 native checks (including both added
audit regressions), all 41 Node tests, the public scan, five repeated control
socket checks and the 25-round eight-pane Ghostty soak. The reviewed validation
run returned exit status zero, not cancelled, with untruncated output. The real
Codex probe results above predate this merge; its implementation is unchanged.
