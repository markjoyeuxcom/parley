# Releasing Parley for macOS

Parley's release workflows are deliberately manual and fail-closed. The
unnotarized test beta becomes a GitHub prerelease only after deterministic
checks, the real eight-pane Ghostty soak, packaging and launch verification
succeed.
The notarized release additionally requires Developer ID signing, Apple
notarization, Gatekeeper assessment and Sparkle feed signing before it
retains verified, unpublished assets for review.

## Locked release dependencies

The exact Sparkle and `libghostty-spm` pins live in `native/Package.swift`
and `native/Package.resolved`. Check those files rather than relying on a
second version list here. Review official release and security notes before
updating either dependency, and keep `THIRD_PARTY_NOTICES.md` consistent.

## One-time signing setup

Create a Developer ID Application certificate for the release identity and an
App Store Connect API key authorized for notarization. Export the certificate
and private key as a password-protected PKCS#12 file. Keep both outside the
repository.

Generate one Sparkle Ed25519 keypair with the `generate_keys` tool from the
resolved Sparkle artifact:

```bash
native/.build/artifacts/sparkle/Sparkle/bin/generate_keys --account com.markjoyeux.parley
native/.build/artifacts/sparkle/Sparkle/bin/generate_keys --account com.markjoyeux.parley -p
native/.build/artifacts/sparkle/Sparkle/bin/generate_keys --account com.markjoyeux.parley -x /private/tmp/parley-sparkle-private-key
```

The public output is safe to embed in the app. The exported private-key file is
equivalent to a password: set mode 0600, place its exact contents in the
repository secret below, keep an offline recovery copy and delete the temporary
file. Never commit either release private key, a PKCS#12 archive or its
password.

Configure these as GitHub Actions repository secrets (Settings › Secrets and
variables › Actions). Only the manual draft-release workflow reads them.

| Secret | Exact value |
| --- | --- |
| `MACOS_DEVELOPER_ID_APPLICATION` | Full `Developer ID Application: …` identity shown by `security find-identity -v -p codesigning` |
| `MACOS_DEVELOPER_ID_P12_BASE64` | Base64 encoding of the PKCS#12 file |
| `MACOS_DEVELOPER_ID_P12_PASSWORD` | PKCS#12 export password |
| `APPLE_NOTARY_KEY_ID` | App Store Connect API key id |
| `APPLE_NOTARY_ISSUER_ID` | App Store Connect issuer UUID |
| `APPLE_NOTARY_KEY_P8_BASE64` | Base64 encoding of the API key `.p8` file |
| `SPARKLE_PUBLIC_ED_KEY` | Exact base64 public key printed by `generate_keys -p` |
| `SPARKLE_PRIVATE_ED_KEY` | Exact contents of the file exported by `generate_keys -x` |

The workflow writes private material only under the disposable macOS runner's
temporary directory, imports the certificate into an ephemeral keychain and
removes both on exit whether or not the release succeeded. Release notes must
exist before signing and notarization begin. Signing material is never an
artifact. The workflow refuses missing secrets. The release script passes
private material to fixed-argument Apple and Sparkle tools; no key is written
into an artifact.

## Where releases run

The source of truth is `github.com/markjoyeuxcom/parley`, a public
repository, and releases are published there. Between 7 September and 10
October 2026 the project lived at `gitlab.com/markjoyeuxcom/apps/parley` with
a self-hosted Tart runner and GitLab releases v0.1.25 to v0.1.65; that
project is kept only as history. GitHub's hosted Apple silicon runners cost a
public repository nothing, so CI, the test-beta workflow and the notarized
draft workflow all run there, on `macos-latest`.

Every workflow installs the pinned, checksummed nodejs.org Node build named in
`.github/workflows/ci.yml` and runs `npm test` as its four parts, so the
checks half can leave the two Docker-only deterministic checks out with an
explicit `--skip` that prints each skipped name; the hosted runner has no
Docker daemon, and a local `npm test` on a Mac with Docker still runs them.

To cut a test beta:

1. Bump `version` in `package.json` and add `.github/release-notes/vX.Y.Z.md`
   in a pull request; merge it once CI is green.
2. Tag the merge commit `vX.Y.Z` and push the tag.
3. Run the **Prepare unnotarized macOS test beta** workflow (Actions › Run
   workflow) with that tag. It checks out the exact tag, runs the
   deterministic checks, the 25-round Ghostty soak, packaging, launch
   verification and checksum assembly, then publishes a prerelease with the
   DMG, ZIP, manifest, checksums, install guide and soak report. It refuses
   a tag that already has a release: delete that release deliberately
   before rerunning.
4. Review the prerelease's checksums, soak report and install guide. Download
   from the release page or with `gh release download vX.Y.Z -R
   markjoyeuxcom/parley`.

## Unnotarized test betas

When current features need installation testing before Developer ID credentials
are configured, use the **Prepare unnotarized macOS test beta** workflow
described above. It is an explicit exception for prerelease testing, not a
fallback from failed notarization.

The workflow requires an existing matching version tag, runs the deterministic
checks and real Ghostty soak, invokes `npm run release:mac:beta`, verifies the
ZIP, DMG, upgrade and uninstall lifecycle, proves the final bundled executable
remains alive past dynamic library loading, and publishes the prerelease with
the workflow's own token. Its manifest and install guide state that the app is
ad-hoc signed without the hardened runtime and is not notarized. Production
Developer ID releases retain the hardened runtime. The beta workflow never
emits an appcast or Homebrew cask and cannot enter the stable automatic-update
channel.

Review the prerelease's checksums, soak report and install guide before
installing. Install it only from the expected GitHub release and follow the
documented Privacy & Security **Open Anyway** flow; never disable Gatekeeper
globally.

## Prepare production assets

1. Merge the intended version and matching `.github/release-notes/v<version>.md`,
   then create the `v<version>` tag at that exact commit.
2. Ensure the signing secrets above are configured on the repository. Run
   the two Docker-only checks on a Mac with Docker; the hosted runner
   explicitly skips them and does not claim they passed.
3. Run the manual **Prepare macOS draft release** workflow with the tag. It
   runs the deterministic checks and the 25-round Ghostty soak, then signs,
   notarizes, verifies Gatekeeper and proves that the packaged app reaches
   its event loop.
4. Review the draft release's DMG, ZIP, release manifest, checksums, install
   guide, `appcast.xml`, `parley.rb`, release notes and soak report. A failed
   run creates no draft. The signing keychain and private files are removed
   on exit and the hosted runner is disposable.
5. Verify installation and updating with the signed candidate. Publishing the
   draft is a separate, explicit action; the workflow does not publish, push
   a tag, update the feed or merge a cask change. Publishing a non-prerelease
   triggers the cask workflow, which proposes `Casks/parley.rb` through a
   pull request and never pushes to main.

Production preparation cannot be validated without real Developer ID, notary
and Sparkle signing credentials. A successful beta job is not evidence that
these production gates passed.

Both release workflows launch the final packaged executable on the clean macOS
runner and require it to remain alive for the smoke-test window. This catches
dyld and embedded-framework signature failures that static `codesign` checks do
not exercise.

The release script submits the signed ZIP for notarization, staples the app,
rebuilds the archives from that stapled app, notarizes and staples the DMG, then
runs `codesign`, `stapler` and `spctl`. Sparkle's official `generate_appcast`
tool must produce both an Ed25519 enclosure signature and a signed-feed footer.
The cask SHA-256 is calculated only after the final DMG has been stapled.

## Verify agent awareness in another project

After changing the shared protocol or a launch adapter, use a person-supervised
check in the newly built app. This is a manual vendor-session check, separate
from deterministic tests; it can consume subscription quota.

1. Create an unrelated temporary folder with no Parley repository instructions.
   Open it in Parley, then explicitly start one pane for each installed vendor.
   Resolve that vendor's normal permission and folder-trust prompts.
2. Ask each agent which Parley protocol version it received at launch, before
   asking it to read a reference. Then ask it to run `parley whoami`,
   `parley help` and `parley protocol`. Record the vendor's declared version,
   the app-owned launch stamp and the command outcomes separately. A printed
   reference or a launch stamp alone is not evidence of initial uptake.
3. Confirm the response distinguishes Relay from Paste, Ask from Delegate,
   reviewed context from agent claims, and native-only verdicts from agent work.
   For Copilot, inspect `/instructions` to confirm the generated directory is
   discovered and enabled. Test Agy first: its added-directory uptake remains
   unverified until this check demonstrates it.
4. Explicitly restart each pane through its vendor-owned Resume path and repeat.
   Also try the absolute `"$PARLEY_COMMAND" protocol` fallback with a PATH
   that omits Parley's bin directory, retaining normal vendor tool approvals.
5. Record app build, installed vendor CLI versions, fresh/resumed outcomes and
   any manual reminder required. Restore the person's normal workspace after
   the check. Do not infer knowledge from terminal activity or lifecycle hooks.

## Review and publish

Before publishing the draft:

- install the DMG on a clean supported Apple-silicon Mac;
- confirm Gatekeeper opens it without **Open Anyway**;
- verify the exact checksums and release manifest;
- run one explicit stable update check without enabling automatic checks;
- confirm canceling Parley's quit dialog leaves every live pane running;
- confirm approving quit ends the app-owned panes and lets Sparkle replace and
  relaunch the application;
- inspect `appcast.xml` and `parley.rb` for the exact tag and artifact URL.

Publishing the release triggers **Propose Homebrew cask update**. That workflow
downloads the cask from the published release, runs Homebrew style and Parley's
public scan, pushes an automation branch and opens a pull request. Review and
merge that PR to make the release available from this repository's tap; the
workflow never pushes directly to main.

```bash
brew tap markjoyeuxcom/parley https://github.com/markjoyeuxcom/parley
brew install --cask markjoyeuxcom/parley/parley
```

## Update behavior and recovery

Only a bundled Production app with the exact fixed HTTPS feed, a canonical
32-byte Ed25519 public key, signed-feed verification and pre-extraction
verification starts Sparkle. Development and locally packaged builds without a
public key show the channel as unavailable.

Automatic checking is off by default and background installation is disabled.
The person may opt into checks, but download and replacement remain visible.
Updater-initiated termination passes through Parley's ordinary confirmation;
canceling it preserves the app and its panes.

Do not rotate the Developer ID certificate and Sparkle key in the same release.
If any signing or notarization stage fails, leave the prior published release
and appcast untouched, correct the release input and rerun the notarized
release workflow.

## Experimental container acceptance

The greenfield release includes the reviewed container implementation with its
known compatibility limits. Untested images, daemons or vendor flows are
follow-ups, not blanket release blockers. Keep the tested configuration and
remaining work explicit in the release notes; do not describe a test that was
not run as passing. The normal build, regression, soak, packaging and launch
checks still apply.

When expanding compatibility, record the local daemon, exact image ID and the
vendor versions from inside that image (`docs/parley-agents-fetch.sh` prints
the versions it fetched for the one-image recipe in
`docs/container-images.md`). Run the three explicit Docker checks against
that image (bypass, transport and Ghostty; the commands are in AGENTS.md and
the image guide), then the person-supervised steps in
[docs/test-scenarios.md, P1.3](docs/test-scenarios.md#p13-container-pane-acceptance). Do not mount host credentials or replace subscription login with API
keys, and never claim that an original vendor process survived a relaunch.
