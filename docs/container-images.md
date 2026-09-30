# Building a Parley-compatible container image

Parley never builds or pulls images. You build one locally, then select it in
the native permission review for any agent pane. This describes what that
image must contain and how to check it before you rely on it.

Everything below is taken from the image probe in `ContainerPaneService` and
the launch arguments in `ContainerPanes`, not from an image that happened to
work.

## What Parley requires

**The vendor executable**, at exactly this path for the pane's vendor:

- `/usr/local/bin/claude`
- `/usr/local/bin/codex`
- `/usr/local/bin/agy`
- `/usr/local/bin/copilot`

One image may carry several; the probe checks only the vendor you selected.

**These utilities**, executable at exactly these absolute paths:

```
/bin/cat  /bin/chown  /bin/date  /bin/mkdir  /bin/pwd  /bin/rm  /bin/rmdir
/bin/sh   /bin/sleep  /bin/true  /usr/bin/id  /usr/bin/printf
/usr/bin/stat  /usr/bin/tr
```

The paths are literal. An image that has `stat` somewhere else does not
satisfy this, even though a shell would find it on `PATH`.

**Two more capabilities:**

- `/usr/bin/stat -c '%u:%a'` must work, so `stat` must accept GNU-style
  `-c FORMAT`.
- Either `/proc/sys/kernel/random/uuid` must be readable or `/usr/bin/uuidgen`
  must be executable.

## The shape Parley runs it in

The image has to tolerate all of this. None of it is configurable per image.

- **An arbitrary numeric user.** Parley passes `--user <your host uid>:<gid>`.
  That user almost certainly does not exist in the image's `/etc/passwd`, so
  nothing may depend on a named account, a home entry, or a login shell.
- **No root and no privilege escalation at runtime:** `--cap-drop=ALL` and
  `--security-opt=no-new-privileges=true`.
- **`HOME=/home/parley`**, backed by a named volume that carries the vendor's
  login and conversations between containers. Create the directory in the
  image so the mount point exists. Parley chowns it to your uid:gid once, as a
  separate step, before the pane starts, and mounts the volume with
  `volume-nocopy=true` in both steps: nothing you put under `/home/parley` in
  the image reaches the volume. (Without nocopy, Docker copies the image
  directory's root ownership into the still-empty volume on the pane's own
  create, undoing the chown, and the vendor cannot write its home. Every image
  built from this page before 14 September 2026 hit that; the spike image
  escaped it only because it had no `/home/parley` at all.)
- **`--workdir` is your project folder's host path**, bind-mounted at the same
  path inside the container. The image must not assume a working directory.
- **`PATH` is replaced** with the shim directory, then `/usr/local/bin`,
  `/usr/bin`, `/bin`. A `PATH` set in the image is not used.
- Mounts are the project folder and the pane's own endpoint (writable), the
  protocol and shim directories (read-only), the home volume, and for a linked
  worktree the shared Git directory. The Docker socket and your host vendor
  login are never mounted.
- `--network=bridge` at run time; the image probe itself runs with
  `--network=none`, so nothing in the image may need the network to start.

## Which base images satisfy this

Checked by running the real probe against each, as a non-root arbitrary uid
with capabilities dropped:

| Base | Result |
| --- | --- |
| `debian:stable-slim` | passes unmodified |
| `ubuntu:24.04` | passes unmodified |
| `node:22-slim` | passes unmodified |
| `alpine:3` | **fails** — `/usr/bin/stat` missing |

Debian and Ubuntu pass because they use a merged `/usr`, so `/bin` and
`/usr/bin` resolve to the same place. Alpine does not: its BusyBox `stat`
lives at `/bin/stat`, and `apk add coreutils` still installs to `/bin/stat`,
so `/usr/bin/stat` does not exist either way. Adding the symlink fixes it, and
`stat` is the only path Alpine is missing — `/usr/bin/id`, `/usr/bin/printf`
and `/usr/bin/tr` are already there.

## Every vendor in one image

One image can carry all four vendors, and this is the simplest way to run
container panes: build it once, then choose it for any agent pane, whatever
the vendor. Each pane still runs in a container of its own, with its own home
volume, sign-in and pane credential; only the image is shared.

`docs/parley-agents-fetch.sh` fetches the Linux arm64 builds of Claude Code,
Codex (with its optional code-mode helper, for Codex's `code_mode_host`
feature), Agy and Copilot, and
checks each against the checksum its publisher states: Claude's release
manifest, GitHub's recorded digest for Codex and Copilot, and Agy's manifest.
It also copies the Prax app's payload (see [Reaching a service on your
Mac](#reaching-a-service-on-your-mac)). Nothing is pinned: it takes Claude's
stable release and the latest of the others, and prints what it fetched.

```bash
sh docs/parley-agents-fetch.sh ~/parley-agents &&
  docker build -t parley-agents:local -f docs/parley-agents.Dockerfile ~/parley-agents
```

`docs/parley-agents.Dockerfile` puts the four executables at the paths Parley
expects on `node:22-slim`, which passes the probe unmodified and supplies the
Node that Prax's CLI needs. Rebuild when a vendor or Prax updates.

On 30 September 2026 this built a 1.9 GB image with Claude Code 2.1.285, Codex
0.159.2, Agy 1.2.14, Copilot 1.0.90 and Prax 0.39.0. It passed the probe
below; every vendor printed its version with and without its bypass flag as
an arbitrary uid with no capabilities and no network; and Parley's three
Docker checks passed against it, from the repository:

```bash
for check in bypass transport ghostty; do
  node scripts/run-native-swift.mjs run --package-path native \
    parley-native-checks --container-$check-spike parley-agents:local
done
```

## Example: Debian base

Fetch the vendor's Linux build for your architecture rather than pinning a
version here; these move, and this file should not pretend to track them.

```dockerfile
FROM debian:stable-slim

# ca-certificates for the vendor CLI's own network calls at run time.
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates git \
 && rm -rf /var/lib/apt/lists/*

# Install the vendor CLI to the exact path Parley expects. Replace the COPY
# with however you obtain the Linux executable; verify it against the
# publisher's checksum before trusting it.
COPY codex-linux-arm64 /usr/local/bin/codex
RUN chmod 0755 /usr/local/bin/codex

# HOME for the named volume Parley mounts and chowns.
RUN mkdir -p /home/parley

# No USER line: Parley supplies --user at run time.
```

Swap `codex` for `claude` to build a Claude image.

## Example: Agy and Copilot

Both publishers ship Linux arm64 builds. Fetch them outside the build, verify
them, then copy them in; nothing here pins a version.

Agy publishes a manifest per platform with the payload's SHA-512. This is what
its own installer does, minus the shell-profile edits:

```bash
base=https://antigravity-cli-auto-updater-974169037036.us-central1.run.app
curl -fsSL "$base/manifests/linux_arm64.json" -o agy-manifest.json
url=$(sed -n 's/.*"url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' agy-manifest.json)
sha=$(sed -n 's/.*"sha512"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' agy-manifest.json)
curl -fsSL -o agy.tar.gz "$url"
[ "$(shasum -a 512 agy.tar.gz | cut -d' ' -f1)" = "$sha" ] || exit 1
tar -xzf agy.tar.gz antigravity && mv antigravity agy
```

Copilot's standalone build is a GitHub release asset,
`copilot-linux-arm64.tar.gz` on github/copilot-cli; it needs no Node in the
image. Verify it against the release before trusting it.

```dockerfile
FROM debian:stable-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates git \
 && rm -rf /var/lib/apt/lists/*

COPY --chmod=0755 agy /usr/local/bin/agy
COPY --chmod=0755 copilot /usr/local/bin/copilot

RUN mkdir -p /home/parley
```

To carry both, and Claude Code and Codex too, see [Every vendor in one
image](#every-vendor-in-one-image).

Two things Parley learned building this on 14 September 2026:

- Copilot's binary is a launcher. On first start it unpacks about 150 MB into
  `~/.cache/copilot` and loads a native addon from there, so its home must
  allow executables and have room. The pane's named volume does; Parley's
  image probe mounts its temporary home with `exec,size=1g` for the same
  reason. A `noexec` home fails with "failed to map segment from shared
  object".
- Agy is a dynamically linked Go binary; `debian:stable-slim` satisfies it
  with no extra packages.

## Example: Alpine base

Only if you want the smaller base. It needs the one symlink.

```dockerfile
FROM alpine:3

RUN apk add --no-cache coreutils ca-certificates git \
 && ln -sf /bin/stat /usr/bin/stat

COPY codex-linux-arm64 /usr/local/bin/codex
RUN chmod 0755 /usr/local/bin/codex
RUN mkdir -p /home/parley
```

## Check an image before you use it

Run the same utility contract Parley runs, under the same restrictions, so a
failure tells you about the image rather than about your shell:

```bash
docker run --rm --network=none --cap-drop=ALL \
  --security-opt=no-new-privileges=true \
  --user "$(id -u):$(id -g)" --entrypoint /bin/sh <image> -c '
set -eu
for u in /bin/cat /bin/chown /bin/date /bin/mkdir /bin/pwd /bin/rm /bin/rmdir \
         /bin/sh /bin/sleep /bin/true /usr/bin/id /usr/bin/printf \
         /usr/bin/stat /usr/bin/tr; do
  [ -x "$u" ] || { printf "Missing: %s\n" "$u" >&2; exit 78; }
done
/usr/bin/stat -c "%u:%a" /bin/sh >/dev/null || exit 78
[ -r /proc/sys/kernel/random/uuid ] || [ -x /usr/bin/uuidgen ] || exit 78
printf "PROBE OK\n"'
```

Exit 78 means the image does not meet the contract. Parley's own review runs
this and then starts the vendor executable, so an image passing here can still
be refused if the vendor binary itself will not start. The vendor start is
`--version`, except for Codex without bypass, where it is
`codex sandbox -- /bin/true`, which also shows whether Codex's sandbox works
there. With bypass selected, each vendor starts with its bypass flag.

## Using an image for a pane

- **A new pane.** Choose **Pane › New Agent Pane…** (or the toolbar's Pane
  menu › Agent), pick the vendor, set **Runs** to **In a container**, type the
  image name (for example `parley-agents:local`), decide on **Bypass vendor
  permissions** (the flags it passes and what it opens are in the
  [README](../README.md#container-panes-experimental)), then press **Check
  Image and Daemon** and Start. The check
  runs the probe and pins the image's ID for that launch.
- **Each start is checked.** A start, restart or resume review fills in the
  pane's image name and asks for the check again, and Start waits for it. The
  check reads the name afresh. That is where a rebuilt image, or a different
  name you type, takes effect. A running pane keeps the image it was checked
  with, so rebuilding a tag changes nothing for it until it starts again.
- **The home volume belongs to the pane, not the image.** It is named after
  the pane, so its sign-in, conversations and anything written into its home
  (such as the [Prax step](#example-the-prax-cli)) survive restarts and a
  change of image. A new pane starts with an empty one. Delete a volume in
  **Status Center › Health › Containers**.
- **The first run of a pane,** in order: sign in (below), run anything that
  writes into its home, then restart it with Resume so the vendor reads what
  was written.
- **Old images.** Remove one with `docker image rm <name>` once no pane uses
  it. Docker refuses while a container still uses it.

## Signing in

Sign in inside the pane, with the vendor's own flow. Parley never mounts your
Mac's vendor login and never substitutes an API key. The login is kept in the
pane's home volume, so a restart or a new image keeps it and a new pane asks
again. Command-click opens a printed address in your Mac's browser.

- **Codex:** choose **Sign in with Device Code**, which needs no port: open
  the link on the Mac and enter the code. OpenAI recommends it when the
  browser callback cannot arrive
  ([authentication guide](https://learn.chatgpt.com/docs/auth#login-on-headless-devices)).
  For browser sign-in instead, enter 1455 as **Published port** in the
  review: Codex's callback returns to `localhost:1455`, and Parley forwards
  that port from the Mac to the container, on 127.0.0.1 only. Reported working
  by device code on 9 September 2026.
- **Claude Code:** its paste-the-code flow, which needs no port. No container
  sign-in has been recorded yet.
- **Agy:** choose Google sign-in, open the printed address on the Mac and paste
  the code back. Signed in from a container on 25 September 2026 (the method
  was not recorded); the login survived the container's removal and a fresh
  start, and a resumed session took up the protocol.
- **Copilot:** confirm its folder trust first, then its device-code flow,
  which needs no port. Not yet signed in from a container.

Whether login survives quitting and relaunching Parley is still a human check
([test-scenarios.md, P1.3](test-scenarios.md#p13-container-pane-acceptance)).

## Reaching a service on your Mac

A pane runs with `--network=bridge`, so the vendor inside can reach services
on your Mac as any container on your Docker runtime can. Parley adds nothing
for this and takes nothing away. Three things decide whether it works:

- **The address.** `host.docker.internal` names the Mac from inside the
  container. OrbStack forwards it to services the Mac binds only to
  `127.0.0.1` (checked on 30 September 2026). Other runtimes were not checked,
  and a service bound only to loopback may be out of reach through them.
- **Configuration.** Parley passes none of your own environment variables and
  no mounts beyond those listed above. A tool that needs an address or a
  setting gets it from the image (`ENV`) or from a file in the pane's home
  volume, written from inside the pane. Never put a token or password in an
  image: anyone with the image can read its layers.
- **Host checks.** A local service that guards against DNS rebinding refuses a
  request whose `Host` header is not a loopback name, so it answers on the Mac
  and returns 403 through `host.docker.internal`. Allow that one name in the
  service's own configuration rather than turning the guard off.

What this opens: every process in that container, and in any other container
on the same Docker runtime, can reach the service, and with **Bypass vendor
permissions** the vendor uses it without asking. The container remains the
boundary for your files, not for what the service will do when a container
asks. Only the image probe runs with `--network=none`.

Instructions do not follow either. A vendor in a container does not read your
Mac's global instruction files (`~/.claude/CLAUDE.md` and each vendor's
equivalent): its home is the pane's volume, which the image cannot pre-fill.
Put guidance for the tool in the project's own `AGENTS.md`, or in the vendor's
global rules from inside the pane, where the volume keeps it.

### Example: the Prax CLI

`docs/parley-agents.Dockerfile` ([Every vendor in one
image](#every-vendor-in-one-image)) carries the CLI of Prax, a memory app that
listens on the Mac's loopback. What it took:

- **The CLI on Linux.** The Mac's `prax` command runs the app's macOS binary,
  which cannot run here, but the CLI itself is plain Node. The image is based
  on `node:22-slim` and carries a copy of the app's
  `Contents/Resources/resources/app` folder. Prax's own installer writes the
  `prax` shim at build time with `--cli`, into `/usr/local/bin`, which is on
  the `PATH` Parley gives a pane; the shim names `/usr/local/bin/node`,
  because Parley replaces `PATH`.
- **The address.** `PRAX_API_URL=http://host.docker.internal:49636` is part
  of the image. 49636 is the port the app chose on first launch and saved in
  `~/Library/Application Support/com.moomora.prax/webview-port`; use yours.
- **The host check.** On the Mac, run
  `launchctl setenv PRAX_ALLOWED_HOSTS host.docker.internal`, then quit and
  reopen Prax. `host.docker.internal` then gets through and any other name
  still gets 403. The setting lasts until you log out or restart. No token was
  needed, because the forwarded connection reaches the app from loopback.
- **Instructions, skills and hooks.** On the Mac, Prax's installer
  (`install.sh --instructions --cli --hooks`) writes all three under `HOME`.
  In a pane that is the volume, which the image cannot fill, so run it inside
  each pane once, after the pane has started; the volume keeps the result,
  and a new pane has a new volume. Find the pane's container by its label and
  run the installer there:

  ```bash
  docker ps --filter label=com.parley.pane \
    --format '{{.Names}}  {{.Label "com.parley.pane"}}  {{.Image}}'
  docker exec -e PRAX_BIN_DIR=/usr/local/bin <container name> \
    sh /opt/prax/skills/install.sh --instructions --hooks
  ```

  `docker exec` runs as the pane's user with its `HOME`. Leave out `--cli`:
  the build did it, and `/usr/local/bin` is not writable at run time, so
  passing it stops the installer part-way. `PRAX_BIN_DIR` points the
  installer at the build's shim, so the instructions teach `prax …`. Without
  it the installer looks in `~/.local/bin`, which is not on Parley's `PATH`,
  and teaches the skill scripts' full paths instead. It recognises only a
  shim it wrote itself, so an image whose shim was written by hand (the
  Agy-only recipe merged in MR !133) gets the full paths too: rebuild it
  first. Restart the pane afterwards so the vendor
  reads its new instructions.

  The instructions go where each vendor reads its global rules:
  `~/.claude/CLAUDE.md`, `~/.codex/AGENTS.md` and `~/.gemini/GEMINI.md` (on
  the Mac, Agy reported the Prax section from that file as its global user
  rule, 30 September 2026). Copilot reads `~/.copilot/instructions` only when
  `COPILOT_CUSTOM_INSTRUCTIONS_DIRS` names it, and in a container that
  variable names only Parley's protocol folder, so a Copilot pane does not get
  them this way.

  `--hooks` writes the harvest hook for Claude Code, Codex and Copilot, and
  the instructions then teach `Remember:` proposals, which only those hooks
  collect. Codex runs a new hook only after you trust it with `/hooks` inside
  the pane. The installer has no hook for Agy, on the Mac or here, so no hook
  collects the `Remember:` lines Agy writes in either place.

Checked by running `prax doctor`, `prax task list --all-projects` and `prax
recall` as your uid with every capability dropped, no new privileges,
Parley's `PATH` and an empty home: each reached the app (`prax doctor` exits 2
for warnings about the library itself, as it does on the Mac), and a request
with another `Host` name got 403. The installer step was checked on a volume chowned as Parley's
initializer does it, in a container created with the pane's flags: it wrote
all four instruction files teaching `prax`, the three hooks named the image's
Node, and a new container on the same volume found everything in place.
Whether a signed-in vendor in a container takes up those instructions, and
whether a harvest hook there reaches Prax, was not checked.

## Known limits

- Selecting Codex without **Bypass vendor permissions** requires Codex's own
  sandbox to work inside the container, which the container pane spike found
  unavailable in the tested OrbStack configuration. The separately selected
  legacy Landlock option remains available for compatible images and is
  deprecated. See `docs/container-pane-spike.md`, the record of that spike.
- Sign-in, instruction uptake in a fresh or resumed vendor session, and login
  persistence across a Parley relaunch are human checks; passing the probe
  establishes none of them. What has been observed is under
  [Signing in](#signing-in).
- Agy's own `--sandbox` inside an unprivileged container is untested, as
  Codex's default sandbox was, and **Check Image and Daemon** cannot show it:
  the check runs `agy --version`, while a pane without bypass starts Agy with
  `--sandbox`. If it cannot start, the launch fails visibly and Bypass vendor
  permissions is the container-only alternative.
- Parley does not build, pull, update or recommend images, and nothing here is
  a supported base. You own the image and what is in it.
