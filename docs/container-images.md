# Building a Parley-compatible container image

Parley never builds or pulls images. You build one locally, then select it in
the native permission review for a Claude or Codex pane. This describes what
that image must contain and how to check it before you rely on it.

Everything below is taken from the image probe in `ContainerPaneService` and
the launch arguments in `ContainerPanes`, not from an image that happened to
work.

## What Parley requires

**The vendor executable**, at exactly this path:

- `/usr/local/bin/claude`, or
- `/usr/local/bin/codex`

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
  image. Parley chowns it to your uid:gid once, as a separate step, before the
  pane starts.
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

Swap `codex` for `claude` to build a Claude image. One vendor per image; the
probe checks the one you selected in the review.

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
  probe does not establish any of them.
- Parley does not build, pull, update or recommend images, and nothing here is
  a supported base. You own the image and what is in it.
