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

The exact file that built the verified four-vendor test image is
`docs/parley-agents.Dockerfile`.

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
be refused if the vendor binary itself will not start.

## Known limits

- Selecting Codex without **Bypass vendor permissions** requires Codex's own
  sandbox to work inside the container, which the container pane spike found
  unavailable in the tested OrbStack configuration. The separately selected
  legacy Landlock option remains available for compatible images and is
  deprecated. See `docs/container-pane-spike.md`.
- Image sign-in, instruction uptake in a fresh or resumed vendor session, and
  login persistence across relaunch are human compatibility checks. Passing the
  probe does not establish any of them. Copilot documents a device-code
  sign-in for containers, which needs no published port; Agy documents a
  copy-the-address, paste-the-code flow for hosts without a browser. Neither
  had been signed in from a Parley container when this was written.
- Agy's own `--sandbox` inside an unprivileged container is untested, as
  Codex's default sandbox was; if it cannot start, the launch fails visibly
  and Bypass vendor permissions is the container-only alternative.
- Parley does not build, pull, update or recommend images, and nothing here is
  a supported base. You own the image and what is in it.
