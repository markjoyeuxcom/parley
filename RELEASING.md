# Releasing Parley for macOS

Parley's release job is deliberately manual and fail-closed. It produces an
unpublished GitHub draft only after deterministic checks, the real eight-pane
Ghostty soak, Developer ID signing, Apple notarization, Gatekeeper assessment
and Sparkle feed signing all succeed.

## Locked release dependencies

The repository currently pins Sparkle 2.9.6 and `libghostty-spm` 1.5.2 in both
`native/Package.swift` and `native/Package.resolved`. These values were checked
against their official GitHub release APIs on 2 September 2026. The wrapper
release embeds Ghostty v1.3.1 at commit
`332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28`.

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

## Unnotarized test betas

When current features need installation testing before Developer ID credentials
are configured, use the separate **Prepare unnotarized macOS test beta**
workflow. It is an explicit exception for prerelease testing, not a fallback
from failed notarization.

The workflow requires an existing matching version tag, runs the deterministic
checks and real Ghostty soak, builds the VS Code companion, invokes
`npm run release:mac:beta`, verifies the ZIP, DMG, upgrade and uninstall
lifecycle, proves the final bundled executable remains alive past dynamic
library loading, and creates an unpublished draft marked as a prerelease. Its
manifest and install guide state that the app is ad-hoc signed without the
hardened runtime and is not notarized. Production Developer ID releases retain
the hardened runtime. The beta workflow never emits an appcast or Homebrew cask
and cannot enter the stable automatic-update channel.

Review the draft checksums, soak report and install guide before publishing.
Install it only from the expected GitHub release and follow the documented
Privacy & Security **Open Anyway** flow; never disable Gatekeeper globally.

## Prepare a draft

1. Ensure `package.json` has the intended version, the matching
   `.github/release-notes/v<version>.md` exists, the tree is clean and the tag
   `v<version>` points exactly at that commit.
2. Run `npm test`, `npm run build` and the Ghostty soak from a normal macOS
   terminal or Parley shell pane that permits real child PTYs.
3. Dispatch **Prepare macOS draft release** with the existing tag.
4. Do not publish unless every job is green and the draft contains the DMG,
   ZIP, release manifest, checksums, install guide, `appcast.xml`, `parley.rb`,
   VS Code companion and Ghostty soak report.

Both release workflows launch the final packaged executable on the clean macOS
runner and require it to remain alive for the smoke-test window. This catches
dyld and embedded-framework signature failures that static `codesign` checks do
not exercise.

The release script submits the signed ZIP for notarization, staples the app,
rebuilds the archives from that stapled app, notarizes and staples the DMG, then
runs `codesign`, `stapler` and `spctl`. Sparkle's official `generate_appcast`
tool must produce both an Ed25519 enclosure signature and a signed-feed footer.
The cask SHA-256 is calculated only after the final DMG has been stapled.

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
and appcast untouched, correct the release input and rerun the draft workflow.
