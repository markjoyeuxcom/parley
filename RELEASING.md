# Releasing Parley for macOS

Parley's release jobs are deliberately manual and fail-closed. The
unnotarized test beta becomes a GitLab release only after deterministic checks,
the real eight-pane Ghostty soak, packaging and launch verification succeed.
The notarized release additionally requires Developer ID signing, Apple
notarization, Gatekeeper assessment and Sparkle feed signing before it
produces an unpublished draft.

## Locked release dependencies

The repository currently pins Sparkle 2.9.6 and `libghostty-spm` 1.5.20260906 in both
`native/Package.swift` and `native/Package.resolved`. These values were checked
against their official GitHub release APIs on 7 September 2026. The wrapper
release embeds Ghostty 1.3.2-dev at commit
`c4e16970a803b170e352432424f44192cb59f3ac`.

Do not copy these version numbers into a future update without querying the
official release API again and reviewing the intervening release and security
notes. Keep `THIRD_PARTY_NOTICES.md` consistent with every pin.

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
equivalent to a password: set mode 0600, place its exact contents in the GitHub
secret below, keep an offline recovery copy and delete the temporary file.
Never commit either release private key, a PKCS#12 archive or its password.

Configure these repository Actions secrets:

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

The workflow writes private material only under the GitHub runner's temporary
directory, imports the certificate into an ephemeral keychain and removes both
after the job. The release script passes private material to fixed-argument
Apple and Sparkle tools; no key is written into an artifact.

## Where releases run since 7 September 2026

The source of truth is `gitlab.com/markjoyeuxcom/apps/parley`, and since
8 September 2026 releases are published there as well: each version is a
GitLab release of that project whose files live in the project's generic
package registry as package `parley`, version `vX.Y.Z`. The project is
private, so a release is visible to its members only. GitHub Actions minutes
are exhausted and the GitHub CI workflow is disabled; GitHub keeps the public
copy of the code, the Homebrew tap and the update feed that shipped notarized
builds still check, until those move as well.

The test-beta release is the manual `release-beta` job of the GitLab
pipeline on the macOS runner. It signs in with its own CI job token through
glab's CI auto-login, so the runner's shell user needs no GitLab login and no
personal token is stored anywhere; `glab` must be installed on the runner.
To cut one:

1. Bump `version` in `package.json` and add `.github/release-notes/vX.Y.Z.md`
   in a merge request; merge it once its pipeline is green.
2. Tag the merge commit `vX.Y.Z` and push the tag to `origin`.
3. In GitLab, open the tag's pipeline and start `release-beta`. It runs the
   deterministic checks, the 25-round Ghostty soak, packaging, launch
   verification and checksum assembly exactly as the retired workflow did,
   then creates the release with the DMG, ZIP, manifest, checksums, install
   guide and soak report. It refuses to overwrite a release
   that already exists for the tag: delete that release and its package
   deliberately before rerunning.
4. Review the release's checksums, soak report and install guide on GitLab.
   Members download from the release page or with
   `glab release download vX.Y.Z -R markjoyeuxcom/apps/parley`.

Pushing `main` and tags to the `github` remote keeps the public copy in step
and is a person's manual choice. The GitHub unnotarized test-beta workflow is
removed. The GitHub **Prepare macOS draft release** workflow stays in the
repository as the documented notarized procedure below but is disabled on
GitHub; it can move the same way once the signing and notarization material
is stored as masked GitLab CI variables instead of GitHub Actions secrets.

## Unnotarized test betas

When current features need installation testing before Developer ID credentials
are configured, use the manual `release-beta` job described above. Its
GitHub Actions predecessor, **Prepare unnotarized macOS test beta**, is
retired with the rest of GitHub Actions. The job is an explicit exception for
prerelease testing, not a fallback from failed notarization.

The job requires an existing matching version tag, runs the deterministic
checks and real Ghostty soak, invokes
`npm run release:mac:beta`, verifies the ZIP, DMG, upgrade and uninstall
lifecycle, proves the final bundled executable remains alive past dynamic
library loading, and creates the GitLab release. Its
manifest and install guide state that the app is ad-hoc signed without the
hardened runtime and is not notarized. Production Developer ID releases retain
the hardened runtime. The beta job never emits an appcast or Homebrew cask
and cannot enter the stable automatic-update channel.

Review the release's checksums, soak report and install guide before
installing. Install it only from the expected GitLab release and follow the
documented
Privacy & Security **Open Anyway** flow; never disable Gatekeeper globally.

## Prepare a draft

This is the notarized GitHub workflow. It is retained as the documented
procedure but disabled on GitHub until it moves to GitLab (see above).

1. Ensure `package.json` has the intended version, the matching
   `.github/release-notes/v<version>.md` exists, the tree is clean and the tag
   `v<version>` points exactly at that commit.
2. Run `npm test`, `npm run build` and the Ghostty soak from a normal macOS
   terminal or Parley shell pane that permits real child PTYs.
3. Dispatch **Prepare macOS draft release** with the existing tag.
4. Do not publish unless every job is green and the draft contains the DMG,
   ZIP, release manifest, checksums, install guide, `appcast.xml`, `parley.rb`
   and Ghostty soak report.

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
